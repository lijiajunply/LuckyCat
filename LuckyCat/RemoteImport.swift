import Foundation

enum RemoteImport {
    static let maximumBytes = ConfigurationImport.maximumFileSize
    static let maximumURLLength = 2048
    static let timeout: TimeInterval = 15

    enum Failure: LocalizedError, Equatable {
        case insecureScheme
        case tooLarge
        case status(Int)
        case network

        var errorDescription: String? {
            switch self {
            case .insecureScheme: "仅支持 HTTPS 配置链接。"
            case .tooLarge: "配置内容超过 32 KB 上限。"
            case .status(let code): "服务器返回 HTTP \(code)。"
            case .network: "网络请求失败，请检查链接和网络后重试。"
            }
        }
    }

    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumURLLength,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host(), !host.isEmpty else {
            return nil
        }
        return url
    }

    static func fetch(_ url: URL, session: URLSession? = nil) async throws -> Data {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else {
            throw Failure.insecureScheme
        }

        let session = session ?? Self.session
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("LuckyCat/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.network }
            guard (200...299).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
            if http.expectedContentLength > Int64(maximumBytes) { throw Failure.tooLarge }
            if let finalURL = http.url, finalURL.scheme?.lowercased() != "https" {
                throw Failure.insecureScheme
            }

            var data = Data()
            data.reserveCapacity(min(maximumBytes, 4096))
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw Failure.tooLarge }
                data.append(byte)
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
