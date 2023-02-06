import Foundation
import OpenFeature

public class RemoteKonfidensClient: KonfidensClient {
    private let domain = "konfidens.services"
    private let resolveRoute = "/v1/flags"
    private let targetingKey = "targeting_key"

    private let baseUrl: String
    private var options: KonfidensClientOptions

    private var httpClient: HttpClient
    private var sendApplyEvent: Bool

    init(options: KonfidensClientOptions, session: URLSession? = nil, sendApplyEvent: Bool) {
        self.options = options
        self.baseUrl = "https://resolver.\(options.region.rawValue).\(domain)"
        if let session = session {
            self.httpClient = HttpClient(session: session)
        } else {
            self.httpClient = HttpClient()
        }
        self.sendApplyEvent = sendApplyEvent
    }

    public func resolve(flag: String, ctx: EvaluationContext) throws -> ResolveResult {
        let request = ResolveFlagRequest(
            flag: "flags/\(flag)",
            evaluationContext: try getEvaluationContextStruct(ctx: ctx),
            clientSecret: options.credentials.getSecret(),
            sendApplyEvent: sendApplyEvent)
        guard let url = URL(string: "\(self.baseUrl)\(self.resolveRoute)/\(flag):resolve") else {
            throw KonfidensError.internalError(message: "Could not create service url")
        }

        do {
            let result = try self.httpClient.post(url: url, data: request, resultType: ResolveFlagResponse.self)
            guard result.response.status == .ok else {
                throw mapHttpStatusToError(status: result.response.status, error: result.decodedError, flag: flag)
            }

            guard let response = result.decodedData else {
                throw OpenFeatureError.parseError(message: "Unable to parse request response")
            }

            if response.resolvedFlag.reason == .archived {
                throw KonfidensError.flagIsArchived
            }

            let resolvedValue = try convert(resolvedFlag: response.resolvedFlag, ctx: ctx)
            return ResolveResult.init(resolvedValue: resolvedValue, resolveToken: response.resolveToken)
        } catch let error {
            throw handleError(error: error)
        }
    }

    public func batchResolve(ctx: EvaluationContext) throws -> BatchResolveResult {
        let request = BatchResolveFlagRequest(
            evaluationContext: try getEvaluationContextStruct(ctx: ctx),
            clientSecret: options.credentials.getSecret(),
            sendApplyEvent: sendApplyEvent)
        guard let url = URL(string: "\(self.baseUrl)\(self.resolveRoute):batchResolve") else {
            throw KonfidensError.internalError(message: "Could not create service url")
        }

        do {
            let result = try self.httpClient.post(url: url, data: request, resultType: BatchResolveFlagResponse.self)
            guard result.response.status == .ok else {
                throw mapHttpStatusToError(status: result.response.status, error: result.decodedError)
            }

            guard let response = result.decodedData else {
                throw OpenFeatureError.parseError(message: "Unable to parse request response")
            }

            let resolvedValues = try response.resolvedFlags.map { resolvedFlag in
                try convert(resolvedFlag: resolvedFlag, ctx: ctx)
            }
            return BatchResolveResult(resolvedValues: resolvedValues, resolveToken: response.resolveToken)
        } catch let error {
            throw handleError(error: error)
        }
    }

    public func apply(flag: String, resolveToken: String, appliedTime: Date) throws {
        let appliedFlag = AppliedFlag(
            flag: "flags/\(flag)",
            appliedTime: Date.backport.toISOString(date: appliedTime),
            sentTime: Date.backport.nowISOString)
        let request = ApplyFlagRequest(
            flag: appliedFlag,
            clientSecret: options.credentials.getSecret(),
            resolveToken: resolveToken)
        guard let url = URL(string: "\(self.baseUrl)\(self.resolveRoute)/\(flag):apply") else {
            throw KonfidensError.internalError(message: "Could not create service url")
        }

        do {
            let result = try self.httpClient.post(url: url, data: request, resultType: ApplyFlagResponse.self)
            guard result.response.status == .ok else {
                throw mapHttpStatusToError(status: result.response.status, error: result.decodedError, flag: flag)
            }
        } catch let error {
            throw handleError(error: error)
        }
    }

    private func convert(resolvedFlag: ResolvedFlag, ctx: EvaluationContext) throws -> ResolvedValue {
        guard let responseFlagSchema = resolvedFlag.flagSchema,
            let responseValue = resolvedFlag.value,
            !responseValue.fields.isEmpty
        else {
            return ResolvedValue(
                value: nil,
                contextHash: ctx.hash(),
                flag: try displayName(resolvedFlag: resolvedFlag),
                applyStatus: sendApplyEvent ? .applied : .notApplied)
        }

        let value = try TypeMapper.from(object: responseValue, schema: responseFlagSchema)
        let variant = resolvedFlag.variant.isEmpty ? nil : resolvedFlag.variant

        return ResolvedValue(
            variant: variant,
            value: value,
            contextHash: ctx.hash(),
            flag: try displayName(resolvedFlag: resolvedFlag),
            applyStatus: sendApplyEvent ? .applied : .notApplied)
    }

    private func getEvaluationContextStruct(ctx: EvaluationContext) throws -> Struct {
        guard !ctx.getTargetingKey().isEmpty else {
            throw OpenFeatureError.targetingKeyMissingError
        }

        var evaluationContext = TypeMapper.from(value: ctx)
        evaluationContext.fields[targetingKey] = .string(ctx.getTargetingKey())
        return evaluationContext
    }

    private func mapHttpStatusToError(status: HTTPStatusCode?, error: HttpError?, flag: String = "unknown") -> Error {
        let defaultError = OpenFeatureError.generalError(
            message: "General error: \(error?.message ?? "Unknown error")")

        switch status {
        case .notFound:
            return OpenFeatureError.flagNotFoundError(key: flag)
        case .badRequest:
            return KonfidensError.badRequest(message: error?.message ?? "")
        default:
            return defaultError
        }
    }

    private func handleError(error: Error) -> Error {
        if error is KonfidensError || error is OpenFeatureError {
            return error
        } else {
            return KonfidensError.grpcError(message: "\(error)")
        }
    }
}

extension RemoteKonfidensClient {
    struct ResolveFlagRequest: Codable {
        var flag: String
        var evaluationContext: Struct
        var clientSecret: String
        var sendApplyEvent: Bool
    }

    struct ResolveFlagResponse: Codable {
        var resolvedFlag: ResolvedFlag
        var resolveToken: String?
    }

    struct ResolvedFlag: Codable {
        var flag: String
        var value: Struct? = Struct(fields: [:])
        var variant: String = ""
        var flagSchema: StructFlagSchema? = StructFlagSchema(schema: [:])
        var reason: ResolveReason
    }

    enum ResolveReason: String, Codable, CaseIterableDefaultsLast {
        case unspecified = "RESOLVE_REASON_UNSPECIFIED"
        case match = "RESOLVE_REASON_MATCH"
        case noSegmentMatch = "RESOLVE_REASON_NO_SEGMENT_MATCH"
        case noTreatmentMatch = "RESOLVE_REASON_NO_TREATMENT_MATCH"
        case archived = "RESOLVE_REASON_FLAG_ARCHIVED"
        case unknown
    }

    struct ApplyFlagRequest: Codable {
        var flag: AppliedFlag
        var clientSecret: String
        var resolveToken: String
    }

    struct AppliedFlag: Codable {
        var flag: String
        var appliedTime: String
        var sentTime: String
    }

    struct ApplyFlagResponse: Codable {
    }

    struct BatchResolveFlagRequest: Codable {
        var evaluationContext: Struct
        var clientSecret: String
        var sendApplyEvent: Bool
    }

    struct BatchResolveFlagResponse: Codable {
        var resolvedFlags: [ResolvedFlag]
        var resolveToken: String?
    }
}

extension RemoteKonfidensClient {
    public struct KonfidensClientOptions {
        public var credentials: KonfidensClientCredentials
        public var timeout: TimeInterval
        public var region: KonfidensRegion

        public init(
            credentials: KonfidensClientCredentials, timeout: TimeInterval? = nil, region: KonfidensRegion? = nil
        ) {
            self.credentials = credentials
            self.timeout = timeout ?? 10.0
            self.region = region ?? .europe
        }
    }

    public enum KonfidensClientCredentials {
        case clientSecret(secret: String)

        public func getSecret() -> String {
            switch self {
            case .clientSecret(let secret):
                return secret
            }
        }
    }

    public enum KonfidensRegion: String {
        case europe = "eu"
        case usa = "us"
    }

    private func displayName(resolvedFlag: ResolvedFlag) throws -> String {
        let flagNameComponents = resolvedFlag.flag.components(separatedBy: "/")
        if flagNameComponents.count <= 1 || flagNameComponents[0] != "flags" {
            throw KonfidensError.internalError(message: "Unxpected flag name: \(resolvedFlag.flag)")
        }
        return resolvedFlag.flag.components(separatedBy: "/")[1]
    }
}
