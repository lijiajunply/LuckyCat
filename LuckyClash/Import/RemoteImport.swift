import Foundation

enum RemoteImport {
    nonisolated static let maximumBytes = 8 * 1024 * 1024
    nonisolated static let maximumURLLength = 8192
    nonisolated static let timeout: TimeInterval = 20

    /// Airports hand a decoy "client too old" configuration (fake nodes pointing
    /// at 127.0.0.1:65535) to user agents they read as the original Clash.
    /// Claiming a Meta-capable client returns the real node list, which the
    /// bundled mihomo core can run.
    nonisolated static let userAgent = "clash-verge/v2.4.2"

    struct Response {
        let data: Data
        let finalURL: URL
        let headers: [String: String]

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    enum Failure: LocalizedError, Equatable {
        case insecureScheme
        case tooLarge
        case status(Int)
        case network

        var errorDescription: String? {
            switch self {
            case .insecureScheme: "仅支持 HTTPS 配置链接。"
            case .tooLarge: "配置内容超过 8 MB 上限。"
            case .status(let code): "服务器返回 HTTP \(code)。"
            case .network: "网络请求失败，请检查链接和网络后重试。"
            }
        }
    }

    nonisolated static func url(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumURLLength else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }

    nonisolated static func fetch(_ url: URL, session: URLSession? = nil) async throws -> Data {
        try await download(url, session: session).data
    }

    nonisolated static func download(_ url: URL, session: URLSession? = nil) async throws -> Response {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else {
            throw Failure.insecureScheme
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        if let session {
            return try await download(request, with: session)
        }
        return try await download(request, configuration: configuration)
    }

    nonisolated static func download(
        _ url: URL, configuration: URLSessionConfiguration
    ) async throws -> Response {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else {
            throw Failure.insecureScheme
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await download(request, configuration: configuration)
    }

    nonisolated private static func download(
        _ request: URLRequest, configuration: URLSessionConfiguration
    ) async throws -> Response {
        guard let url = request.url else { throw Failure.network }
        return try await StreamDownload(
            limit: maximumBytes, originalURL: url, configuration: configuration
        ).run(request)
    }

    nonisolated private static func download(
        _ request: URLRequest, with session: URLSession
    ) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.network }
            guard (200...299).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
            if http.expectedContentLength > Int64(maximumBytes) { throw Failure.tooLarge }
            if data.count > maximumBytes { throw Failure.tooLarge }
            if let finalURL = http.url, finalURL.scheme?.lowercased() != "https" {
                throw Failure.insecureScheme
            }
            return Response(
                data: data, finalURL: http.url ?? request.url!, headers: headers(of: http)
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network
        }
    }

    nonisolated static func headers(of response: HTTPURLResponse) -> [String: String] {
        var values: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            values[String(describing: key).lowercased()] = String(describing: value)
        }
        return values
    }

    nonisolated static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// Streams the response and cancels as soon as the declared or streamed size
/// exceeds the limit, so a hostile server cannot make the app buffer an
/// unbounded body.
private final class StreamDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let originalURL: URL
    private let configuration: URLSessionConfiguration
    private var body = Data()
    private var response: HTTPURLResponse?
    private var failure: RemoteImport.Failure?
    private var continuation: CheckedContinuation<RemoteImport.Response, Error>?
    private var session: URLSession?
    private var finished = false

    init(limit: Int, originalURL: URL, configuration: URLSessionConfiguration) {
        self.limit = limit
        self.originalURL = originalURL
        self.configuration = configuration
    }

    func run(_ request: URLRequest) async throws -> RemoteImport.Response {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let session = URLSession(
                configuration: configuration, delegate: self, delegateQueue: nil
            )
            lock.lock()
            self.session = session
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            record(.network)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        if http.expectedContentLength > Int64(limit) {
            record(.tooLarge)
            completionHandler(.cancel)
            return
        }
        if let url = http.url, url.scheme?.lowercased() != "https" {
            record(.insecureScheme)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            record(.insecureScheme)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        lock.lock()
        if failure == nil, body.count + data.count > limit {
            failure = .tooLarge
            lock.unlock()
            session.invalidateAndCancel()
            finish()
            return
        }
        if failure == nil {
            body.append(data)
        }
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        finish()
    }

    private func record(_ failure: RemoteImport.Failure) {
        lock.lock()
        if self.failure == nil { self.failure = failure }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let failure = self.failure
        let response = self.response
        let body = self.body
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()

        if let failure {
            continuation?.resume(throwing: failure)
        } else if let response, (200...299).contains(response.statusCode) {
            continuation?.resume(returning: RemoteImport.Response(
                data: body, finalURL: response.url ?? originalURL,
                headers: RemoteImport.headers(of: response)
            ))
        } else if let response {
            continuation?.resume(throwing: RemoteImport.Failure.status(response.statusCode))
        } else {
            continuation?.resume(throwing: RemoteImport.Failure.network)
        }
    }
}
