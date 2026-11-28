import Clash
import Foundation
import Network

/// The pinned SDK's URL-test convenience method fixes the timeout at 5 s.
/// Use the same loopback-only HTTP API when the user chooses a different timeout.
nonisolated final class ClashDelayRequest: @unchecked Sendable {
    static let defaultTimeout = 5_000
    static let timeoutKey = "delayTestTimeout"
    private static let queue = DispatchQueue(label: "com.luckyfish.LuckyClash.delay.http")
    private static let segmentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private let connection: NWConnection
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response: Data?
    private var received = Data()

    private init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    static func measure(
        name: String, testURL: String, timeout: Int, socketPath: String,
        client: ClashAPIClient, provider: String?
    ) -> Int {
        if timeout == defaultTimeout {
            var delay = -1
            return (try? client.urlTest(name, testURL: testURL, ret0_: &delay)) != nil ? delay : -1
        }
        guard let name = name.addingPercentEncoding(withAllowedCharacters: segmentCharacters) else { return -1 }
        var components = URLComponents()
        components.queryItems = [
            .init(name: "url", value: testURL),
            .init(name: "expected", value: "200-299"),
            .init(name: "timeout", value: String(timeout))
        ]
        guard let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") else { return -1 }
        let deadline = DispatchTime.now() + .milliseconds(timeout + 300)
        var result = ClashDelayRequest(path: socketPath).get("/proxies/\(name)/delay?\(query)", deadline: deadline)
        if result?.status == 404,
           let provider = provider?.addingPercentEncoding(withAllowedCharacters: segmentCharacters) {
            result = ClashDelayRequest(path: socketPath).get(
                "/providers/proxies/\(provider)/\(name)/healthcheck?\(query)", deadline: deadline
            )
        }
        guard let result, result.status == 200,
              let body = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let delay = body["delay"] as? Int, delay > 0, delay <= timeout else { return -1 }
        return delay
    }

    static func providers(client: ClashAPIClient, timeout: Int) -> [String: String] {
        guard timeout != defaultTimeout else { return [:] }
        var error: NSError?
        let payload = client.getProxyProviders(&error)
        guard error == nil, let providers = try? ClashProviderPayload.decode(payload) else { return [:] }
        var result: [String: String] = [:]
        for (name, provider) in providers.sorted(by: { $0.key < $1.key }) where provider.vehicleType != "Compatible" {
            for member in provider.proxies ?? [] where result[member.name] == nil {
                result[member.name] = name
            }
        }
        return result
    }

    private func get(_ target: String, deadline: DispatchTime) -> (status: Int, body: Data)? {
        let request = Data("GET \(target) HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connection.send(content: request, completion: .contentProcessed { [weak self] error in
                    if error == nil { self?.receive() }
                    else { self?.finished.signal() }
                })
            case .failed, .cancelled:
                self.finished.signal()
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
        defer { connection.cancel() }
        guard finished.wait(timeout: deadline) == .success,
              let data = lock.withLock({ response }),
              let headers = data.range(of: Data("\r\n\r\n".utf8)),
              let statusCode = String(decoding: data[..<headers.lowerBound], as: UTF8.self)
                .split(separator: " ", maxSplits: 2).dropFirst().first.flatMap({ Int($0) }) else { return nil }
        return (statusCode, Data(data[headers.upperBound...]))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.received.append(data) }
            if error != nil || self.received.count > 8192 {
                self.finished.signal()
            } else if complete {
                self.lock.withLock { self.response = self.received }
                self.finished.signal()
            } else {
                self.receive()
            }
        }
    }
}
