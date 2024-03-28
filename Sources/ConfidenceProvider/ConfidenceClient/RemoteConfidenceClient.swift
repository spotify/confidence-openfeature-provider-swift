import Foundation
import Confidence
import OpenFeature


public class RemoteConfidenceClient: ConfidenceClient {
    private let targetingKey = "targeting_key"
    private let flagApplier: FlagApplier
    private var options: ConfidenceClientOptions
    private let metadata: ConfidenceMetadata

    private var httpClient: HttpClient
    private var applyOnResolve: Bool

    init(
        options: ConfidenceClientOptions,
        session: URLSession? = nil,
        applyOnResolve: Bool,
        flagApplier: FlagApplier,
        metadata: ConfidenceMetadata
    ) {
        self.options = options
        self.httpClient = NetworkClient(session: session, region: options.region)
        self.flagApplier = flagApplier
        self.applyOnResolve = applyOnResolve
        self.metadata = metadata
    }

    // MARK: Resolver

    public func resolve(flags: [String], ctx: EvaluationContext) async throws -> ResolvesResult {
        let request = ResolveFlagsRequest(
            flags: flags.map { "flags/\($0)" },
            evaluationContext: try getEvaluationContextStruct(ctx: ctx),
            clientSecret: options.credentials.getSecret(),
            apply: applyOnResolve,
            sdk: Sdk(id: metadata.name, version: metadata.version)
        )

        do {
            let result: HttpClientResult<ResolveFlagsResponse> =
            try await self.httpClient.post(path: ":resolve", data: request)
            switch result {
            case .success(let successData):
                guard successData.response.status == .ok else {
                    throw successData.response.mapStatusToError(error: successData.decodedError)
                }
                guard let response = successData.decodedData else {
                    throw OpenFeatureError.parseError(message: "Unable to parse request response")
                }
                let resolvedValues = try response.resolvedFlags.map { resolvedFlag in
                    try convert(resolvedFlag: resolvedFlag, ctx: ctx)
                }
                return ResolvesResult(resolvedValues: resolvedValues, resolveToken: response.resolveToken)
            case .failure(let errorData):
                throw handleError(error: errorData)
            }
        }
    }

    public func resolve(ctx: EvaluationContext) async throws -> ResolvesResult {
        return try await resolve(flags: [], ctx: ctx)
    }

    // MARK: Private

    private func convert(resolvedFlag: ResolvedFlag, ctx: EvaluationContext) throws -> ResolvedValue {
        guard let responseFlagSchema = resolvedFlag.flagSchema,
            let responseValue = resolvedFlag.value,
            !responseValue.fields.isEmpty
        else {
            return ResolvedValue(
                value: nil,
                flag: try displayName(resolvedFlag: resolvedFlag),
                resolveReason: convert(resolveReason: resolvedFlag.reason))
        }

        let value = try TypeMapper.from(object: responseValue, schema: responseFlagSchema)
        let variant = resolvedFlag.variant.isEmpty ? nil : resolvedFlag.variant

        return ResolvedValue(
            variant: variant,
            value: value,
            flag: try displayName(resolvedFlag: resolvedFlag),
            resolveReason: convert(resolveReason: resolvedFlag.reason))
    }

    private func getEvaluationContextStruct(ctx: EvaluationContext) throws -> Struct {
        var evaluationContext = TypeMapper.from(value: ctx)
        evaluationContext.fields[targetingKey] = .string(ctx.getTargetingKey())
        return evaluationContext
    }

    private func handleError(error: Error) -> Error {
        if error is ConfidenceError || error is OpenFeatureError {
            return error
        } else {
            return ConfidenceError.grpcError(message: "\(error)")
        }
    }

    private func convert(resolveReason: ResolveReason) -> ResolvedValue.Reason {
        switch resolveReason {
        case .error, .unknown, .unspecified: return .generalError
        case .noSegmentMatch, .noTreatmentMatch: return .noMatch
        case .match: return .match
        case .archived: return .disabled
        case .targetingKeyError: return .targetingKeyError
        }
    }
}

struct ResolveFlagsRequest: Codable {
    var flags: [String]
    var evaluationContext: Struct
    var clientSecret: String
    var apply: Bool
    var sdk: Sdk
}

struct ResolveFlagsResponse: Codable {
    var resolvedFlags: [ResolvedFlag]
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
    case targetingKeyError = "RESOLVE_REASON_TARGETING_KEY_ERROR"
    case error = "RESOLVE_REASON_ERROR"
    case unknown
}

struct AppliedFlagRequestItem: Codable {
    let flag: String
    let applyTime: String

    init(flag: String, applyTime: Date) {
        self.flag = "flags/\(flag)"
        self.applyTime = Date.backport.toISOString(date: applyTime)
    }
}

struct ApplyFlagsRequest: Codable {
    var flags: [AppliedFlagRequestItem]
    var sendTime: String
    var clientSecret: String
    var resolveToken: String
    var sdk: Sdk
}

struct ApplyFlagsResponse: Codable {
}

struct Sdk: Codable {
    init(id: String?, version: String?) {
        self.id = id ?? "SDK_ID_SWIFT_PROVIDER"
        self.version = version ?? "unknown"
    }

    var id: String
    var version: String
}

private func displayName(resolvedFlag: ResolvedFlag) throws -> String {
    let flagNameComponents = resolvedFlag.flag.components(separatedBy: "/")
    if flagNameComponents.count <= 1 || flagNameComponents[0] != "flags" {
        throw ConfidenceError.internalError(message: "Unxpected flag name: \(resolvedFlag.flag)")
    }
    return resolvedFlag.flag.components(separatedBy: "/")[1]
}
