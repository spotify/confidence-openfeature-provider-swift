import Foundation

typealias HttpClientResult<T> = Result<HttpClientResponse<T>, Error>

protocol HttpClient {
    func post<T: Decodable>(
        path: String,
        data: Codable,
        completion: @escaping (HttpClientResult<T>) async -> Void
    ) async throws

    func post<T: Decodable>(path: String, data: Codable) async throws -> HttpClientResponse<T>
}

struct HttpClientResponse<T> {
    var decodedData: T?
    var decodedError: HttpError?
    var response: HTTPURLResponse
}

struct HttpError: Codable {
    var code: Int
    var message: String
    var details: [String]
}

enum HttpClientError: Error {
    case invalidResponse
    case internalError
}
