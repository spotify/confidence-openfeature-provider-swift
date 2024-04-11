import Foundation

public typealias HttpClientResult<T> = Result<HttpClientResponse<T>, Error>

public protocol HttpClient {
    func post<T: Decodable>(path: String, data: Encodable) async throws -> HttpClientResult<T>
}

public struct HttpClientResponse<T> {
    public var decodedData: T?
    public var decodedError: HttpError?
    public var response: HTTPURLResponse
}

public struct HttpError: Codable {
    public init(code: Int, message: String, details: [String]) {
        self.code = code
        self.message = message
        self.details = details
    }
    public var code: Int
    public var message: String
    public var details: [String]
}

public enum HttpClientError: Error {
    case invalidResponse
    case internalError
}

extension HTTPURLResponse {
    func mapStatusToError(error: HttpError?, flag: String = "unknown") -> Error {
        let defaultError = ConfidenceError.internalError(
            message: "General error: \(error?.message ?? "Unknown error")")

        switch self.status {
        case .notFound:
            return ConfidenceError.badRequest(message: flag) // TODO
        case .badRequest:
            return ConfidenceError.badRequest(message: error?.message ?? "")
        default:
            return defaultError
        }
    }
}
