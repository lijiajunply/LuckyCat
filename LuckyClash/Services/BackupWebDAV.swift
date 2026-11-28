import Foundation

nonisolated enum BackupWebDAV {
    enum Failure: LocalizedError {
        case invalidURL
        case invalidResponse
        case status(Int)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidURL: "请输入有效的 HTTPS WebDAV 文件地址。"
            case .invalidResponse: "WebDAV 服务器响应无效。"
            case .status(let code): "WebDAV 服务器返回 HTTP \(code)。"
            case .tooLarge: "备份文件过大。"
            }
        }
    }

    private static func request(url: URL, method: String, username: String, password: String) throws -> URLRequest {
        guard url.scheme?.lowercased() == "https", url.host() != nil,
              url.user == nil, url.password == nil else { throw Failure.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func upload(_ data: Data, to url: URL, username: String, password: String) async throws {
        var request = try request(url: url, method: "PUT", username: username, password: password)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.upload(for: request, from: data)
        try check(response)
    }

    static func download(from url: URL, username: String, password: String) async throws -> Data {
        let request = try request(url: url, method: "GET", username: username, password: password)
        let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        try check(response)
        guard response.expectedContentLength <= Int64(BackupEncryption.maximumSize * 2) else { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < BackupEncryption.maximumSize * 2 else { throw Failure.tooLarge }
            data.append(byte)
        }
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let old = task.originalRequest?.url, let target = request.url,
                  target.scheme?.lowercased() == "https",
                  old.host()?.lowercased() == target.host()?.lowercased(),
                  (old.port ?? 443) == (target.port ?? 443),
                  task.originalRequest?.httpMethod != "PUT" || [307, 308].contains(response.statusCode) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
