import Foundation
import Confidence

final class NetworkClient: HttpClient {
    private let headers: [String: String]
    private let retry: Retry
    private let timeout: TimeInterval
    private let session: URLSession
    private let region: ConfidenceRegion

    private var baseUrl: String {
        switch region {
        case .global:
            return "https://resolver.confidence.dev/v1/flags"
        case .europe:
            return "https://resolver.eu.confidence.dev/v1/flags"
        case .usa:
            return "https://resolver.us.confidence.dev/v1/flags"
        }
    }

    init(
        session: URLSession? = nil,
        region: ConfidenceRegion,
        defaultHeaders: [String: String] = [:],
        timeout: TimeInterval = 30.0,
        retry: Retry = .none
    ) {
        self.session =
        session
        ?? {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = timeout
            configuration.httpAdditionalHeaders = defaultHeaders

            return URLSession(configuration: configuration)
        }()

        self.headers = defaultHeaders
        self.retry = retry
        self.timeout = timeout
        self.region = region
    }

    func post<T: Decodable>(
        path: String,
        data: Codable
    ) async throws -> HttpClientResult<T> {
        let request = try buildRequest(path: path, data: data)
        let requestResult = await perform(request: request, retry: self.retry)
        if let error = requestResult.error {
            return .failure(error)
        }

        guard let response = requestResult.httpResponse, let data = requestResult.data else {
            return .failure(ConfidenceError.internalError(message: "Bad response"))
        }

        do {
            let httpClientResult: HttpClientResponse<T> =
            try self.buildResponse(response: response, data: data)
            return .success(httpClientResult)
        } catch {
            return .failure(error)
        }
    }

    private func perform(
        request: URLRequest,
        retry: Retry
    ) async -> RequestResult {
        let retryHandler = retry.handler()
        let retryWait: TimeInterval? = retryHandler.retryIn()

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return RequestResult(httpResponse: nil, data: nil, error: HttpClientError.invalidResponse)
            }
            if self.shouldRetry(httpResponse: httpResponse), let retryWait {
                try? await Task.sleep(nanoseconds: UInt64(retryWait * 1_000_000_000))
                return await self.perform(request: request, retry: retry)
            }
            return RequestResult(httpResponse: httpResponse, data: data, error: nil)
        } catch {
            if self.shouldRetry(error: error), let retryWait {
                try? await Task.sleep(nanoseconds: UInt64(retryWait * 1_000_000_000))
                return await self.perform(request: request, retry: retry)
            } else {
                return RequestResult(httpResponse: nil, data: nil, error: error)
            }
        }
    }
}

struct RequestResult {
    var httpResponse: HTTPURLResponse?
    var data: Data?
    var error: Error?
}

// MARK: Private

extension NetworkClient {
    private func constructURL(base: String, path: String) -> URL? {
        let normalisedBase = base.hasSuffix("/") ? base : "\(base)"
        let normalisedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path

        return URL(string: "\(normalisedBase)\(normalisedPath)")
    }

    private func buildRequest(path: String, data: Codable) throws -> URLRequest {
        guard let url = constructURL(base: baseUrl, path: path) else {
            throw ConfidenceError.internalError(message: "Could not create service url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let jsonData = try encoder.encode(data)
        request.httpBody = jsonData

        return request
    }

    private func buildResponse<T: Decodable>(
        response httpURLResponse: HTTPURLResponse?,
        data: Data?
    ) throws -> HttpClientResponse<T> {
        guard let httpURLResponse else {
            throw ConfidenceError.internalError(message: "Invalid response")
        }

        var response: HttpClientResponse<T> = HttpClientResponse(response: httpURLResponse)
        if let responseData = data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if response.response.status == .ok {
                response.decodedData = try decoder.decode(T.self, from: responseData)
            } else {
                do {
                    response.decodedError = try decoder.decode(HttpError.self, from: responseData)
                } catch {
                    let message = String(data: responseData, encoding: String.Encoding.utf8)
                    response.decodedError = HttpError(
                        code: httpURLResponse.statusCode,
                        message: message ?? "unknown",
                        details: []
                    )
                }
            }
        }

        return response
    }

    private func shouldRetry(httpResponse: HTTPURLResponse) -> Bool {
        httpResponse.status?.responseType == .serverError
    }

    private func shouldRetry(error: Error) -> Bool {
        (error as? URLError)?.code == .timedOut
    }
}
