import Foundation

/// An unauthenticated public request. Redirects are refused, not followed to another host.
final class AppUpdateHTTPClient: NSObject, URLSessionTaskDelegate {
    static let endpoint = URL(string: "https://api.github.com/repos/ForLess01/Nuvi_STT/releases/latest")!

    func fetch() async throws -> AppUpdateResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: Self.endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Nuvi-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == Self.endpoint,
              data.count <= 1_048_576 else { throw URLError(.badServerResponse) }
        return AppUpdateResponse(data: data, status: http.statusCode,
                                 retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
