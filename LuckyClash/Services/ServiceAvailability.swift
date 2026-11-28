import Foundation
import Observation

nonisolated enum ServiceTarget: String, CaseIterable, Sendable, Identifiable {
    case chatGPT = "ChatGPT"
    case claude = "Claude"
    case google = "Google"
    case youtube = "YouTube"
    case netflix = "Netflix"

    var id: String { rawValue }

    var url: URL {
        let address: String
        switch self {
        case .chatGPT: address = "https://api.openai.com/compliance/cookie_requirements"
        case .claude: address = "https://claude.ai/cdn-cgi/trace"
        case .google: address = "https://www.google.com/generate_204"
        case .youtube: address = "https://www.youtube.com/premium?hl=en"
        case .netflix: address = "https://www.netflix.com/title/81280792"
        }
        return URL(string: address)!
    }
}

nonisolated struct ServiceAvailabilityResult: Sendable {
    enum Status: Sendable {
        case reachable
        case restricted
        case unavailable
        case unknown
    }
    let target: ServiceTarget
    let status: Status
    let latency: Int?
    let region: String?
}

nonisolated enum ServiceAvailabilityProbe {
    static func check(_ target: ServiceTarget) async -> ServiceAvailabilityResult {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now
        do {
            var request = URLRequest(url: target.url)
            request.setValue("LuckyClash/1.0", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 128 * 1024 { break }
            }
            try Task.checkCancellation()
            let elapsed = start.duration(to: .now)
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return interpret(target, status: http.statusCode, body: String(decoding: data, as: UTF8.self), latency: milliseconds)
        } catch {
            return ServiceAvailabilityResult(target: target, status: .unavailable, latency: nil, region: nil)
        }
    }

    static func interpret(_ target: ServiceTarget, status: Int, body: String, latency: Int) -> ServiceAvailabilityResult {
        let text = body.lowercased()
        var outcome: ServiceAvailabilityResult.Status = (200..<400).contains(status) ? .reachable : .unknown
        var region: String?
        switch target {
        case .chatGPT:
            if text.contains("unsupported_country") { outcome = .restricted }
        case .claude:
            region = body.split(whereSeparator: \.isNewline).first { $0.hasPrefix("loc=") }.map {
                String($0.dropFirst(4)).uppercased()
            }
            if let region, ["AF", "BY", "CN", "CU", "HK", "IR", "KP", "MO", "RU", "SY"].contains(region) {
                outcome = .restricted
            }
        case .youtube:
            if text.contains("premium is not available in your country") ||
                text.contains("premium is not available in your region") {
                outcome = .restricted
            }
            region = match(#"\"(?:GL|countryCode|country_code)\"\s*:\s*\"([A-Za-z]{2})\""#, in: body)
        case .netflix:
            if status == 403 || status == 451 { outcome = .restricted }
        case .google:
            break
        }
        return .init(target: target, status: outcome, latency: latency, region: region)
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range(at: 1), in: text) else { return nil }
        return String(text[range]).uppercased()
    }
}

@MainActor
@Observable
final class ServiceAvailability {
    private(set) var results: [ServiceTarget: ServiceAvailabilityResult] = [:]
    private(set) var isChecking = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        isChecking = false
        results = [:]
    }

    func refresh() {
        cancel()
        isChecking = true
        task = Task {
            await withTaskGroup(of: ServiceAvailabilityResult.self) { group in
                for target in ServiceTarget.allCases {
                    group.addTask { await ServiceAvailabilityProbe.check(target) }
                }
                for await result in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    results[result.target] = result
                }
            }
            if !Task.isCancelled { isChecking = false }
        }
    }
}
