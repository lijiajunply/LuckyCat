import Foundation
import Network
import Observation

/// What a third-party IP lookup says about the address the current traffic
/// leaves by. Reports live in memory only and are never written to disk or
/// diagnostics.
nonisolated struct OutboundIPReport: Equatable, Sendable {
    nonisolated enum Kind: String, Equatable, Sendable {
        case residential
        case mobile
        case business
        case hosting
        case unknown

        var title: String {
            switch self {
            case .residential: "住宅"
            case .mobile: "移动网络"
            case .business: "商业"
            case .hosting: "机房"
            case .unknown: "未知"
            }
        }
    }

    nonisolated enum Quality: String, Equatable, Sendable {
        case good
        case normal
        case risky

        var title: String {
            switch self {
            case .good: "优"
            case .normal: "普通"
            case .risky: "风险"
            }
        }
    }

    var ip: String
    var countryCode: String?
    var country: String?
    var kind: Kind
    var organization: String?
    var asn: Int?
    var isProxy = false
    var isVPN = false
    var isTor = false
    var isAbuser = false
    var source: String
    var checkedAt: Date

    var quality: Quality {
        if isTor || isAbuser { return .risky }
        switch kind {
        case .residential, .mobile, .business: return .good
        case .hosting, .unknown: return .normal
        }
    }

    var flags: [String] {
        var values: [String] = []
        if isTor { values.append("Tor") }
        if isAbuser { values.append("滥用记录") }
        if isVPN { values.append("VPN") }
        if isProxy { values.append("代理") }
        return values
    }

    /// Country names follow the app's Chinese interface.
    var countryName: String {
        if let countryCode, !countryCode.isEmpty,
           let localized = Self.countryLocale.localizedString(forRegionCode: countryCode) {
            return localized
        }
        return country ?? ""
    }

    /// Country names follow the app's Chinese interface. Views show the ISO
    /// code as a badge instead of a flag emoji, because mainland China hides
    /// some regional flags and renders them as a crossed box.
    private static let countryLocale = Locale(identifier: "zh_CN")
}

/// The per-source reasons a lookup failed, kept so the detail sheet can show
/// which service answered and which did not.
nonisolated struct OutboundIPFailure: LocalizedError, Equatable, Sendable {
    nonisolated struct SourceFailure: Error, Equatable, Sendable {
        var source: String
        var reason: String
    }

    var failures: [SourceFailure]

    var errorDescription: String? {
        let details = failures.map { "\($0.source)：\($0.reason)" }.joined(separator: "；")
        return details.isEmpty ? "未能获取出口 IP。" : details
    }
}

/// One outbound IP check. A closure keeps the controller testable without
/// touching the network.
nonisolated struct OutboundIPLookup: Sendable {
    var perform: @Sendable () async throws -> OutboundIPReport

    static let live = OutboundIPLookup {
        try await OutboundIPSources.lookup()
    }
}

@MainActor
@Observable
final class OutboundIPDetection {
    private(set) var report: OutboundIPReport?
    private(set) var failure: OutboundIPFailure?
    private(set) var isChecking = false
    private(set) var lastAttemptAt: Date?

    @ObservationIgnored private let lookup: OutboundIPLookup
    @ObservationIgnored private var task: Task<Void, Never>?

    init(lookup: OutboundIPLookup = .live) {
        self.lookup = lookup
    }

    /// Runs a check unless one already finished recently. Used when the page
    /// appears, so switching tabs does not query the services repeatedly.
    @discardableResult
    func refreshIfStale(within interval: TimeInterval = 30) -> Task<Void, Never>? {
        if let lastAttemptAt, Date.now.timeIntervalSince(lastAttemptAt) < interval {
            return nil
        }
        return refresh()
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        task?.cancel()
        isChecking = true
        failure = nil
        let lookup = lookup
        let running = Task { [weak self] in
            do {
                let report = try await lookup.perform()
                guard !Task.isCancelled else { return }
                self?.apply(report)
            } catch is CancellationError {
                // A newer check owns the spinner.
            } catch let failure as OutboundIPFailure {
                guard !Task.isCancelled else { return }
                self?.apply(failure)
            } catch {
                guard !Task.isCancelled else { return }
                self?.apply(OutboundIPFailure(
                    failures: [.init(source: "检测", reason: error.localizedDescription)]
                ))
            }
        }
        task = running
        return running
    }

    private func apply(_ report: OutboundIPReport) {
        self.report = report
        failure = nil
        isChecking = false
        lastAttemptAt = .now
    }

    private func apply(_ failure: OutboundIPFailure) {
        self.failure = failure
        isChecking = false
        lastAttemptAt = .now
    }
}

/// The HTTPS services the app asks for the current exit address. Primaries
/// are queried together and the first usable answer wins; fallbacks wait a
/// little so a healthy primary cancels them before they see the address.
nonisolated enum OutboundIPSources {
    nonisolated struct Source: Sendable {
        let name: String
        let url: URL
        /// Fallback sources wait before asking, so a healthy primary answer
        /// cancels them before they ever see the user's address.
        let delay: TimeInterval
        let parse: @Sendable (Data) throws -> OutboundIPReport
    }

    static let sources: [Source] = [
        Source(
            name: "ipquery.io",
            url: URL(string: "https://api.ipquery.io/?format=json")!,
            delay: 0,
            parse: parseIpQuery
        ),
        Source(
            name: "ident.me",
            url: URL(string: "https://ident.me/json")!,
            delay: 0,
            parse: parseIdentMe
        ),
        Source(
            name: "ipwho.is",
            url: URL(string: "https://ipwho.is/")!,
            delay: 1.5,
            parse: parseIpWhoIs
        ),
        Source(
            name: "ipapi.is",
            url: URL(string: "https://api.ipapi.is/")!,
            delay: 2.5,
            parse: parseIpApiIs
        ),
    ]

    static let maximumBytes = 64 * 1024
    static let timeout: TimeInterval = 8

    nonisolated static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    static func lookup(session: URLSession? = nil) async throws -> OutboundIPReport {
        let owned = session == nil
        let session = session ?? URLSession(configuration: sessionConfiguration)
        defer { if owned { session.finishTasksAndInvalidate() } }

        return try await withThrowingTaskGroup(
            of: Result<OutboundIPReport, OutboundIPFailure.SourceFailure>.self
        ) { group in
            for source in sources {
                group.addTask {
                    await source.fetch(session: session)
                }
            }
            var failures: [OutboundIPFailure.SourceFailure] = []
            for try await result in group {
                switch result {
                case .success(let report):
                    group.cancelAll()
                    return report
                case .failure(let failure):
                    failures.append(failure)
                }
            }
            let order = Dictionary(
                uniqueKeysWithValues: sources.enumerated().map { ($1.name, $0) }
            )
            throw OutboundIPFailure(
                failures: failures.sorted {
                    (order[$0.source] ?? 0) < (order[$1.source] ?? 0)
                }
            )
        }
    }

    // MARK: - Parsing

    static func parseIpQuery(_ data: Data) throws -> OutboundIPReport {
        let json = try object(from: data)
        let location = object(json["location"])
        let isp = object(json["isp"])
        let risk = object(json["risk"])
        return OutboundIPReport(
            ip: try validIP(json["ip"]),
            countryCode: countryCode(location["country_code"]),
            country: text(location["country"]),
            // ipquery reports whether an address is mobile or hosted, but not
            // whether a remaining address is residential or business; the
            // former is the only useful inference left.
            kind: kind(
                hosting: bool(risk["is_datacenter"]),
                mobile: bool(risk["is_mobile"]),
                declared: nil,
                inferResidential: !risk.isEmpty
            ),
            organization: text(isp["org"]) ?? text(isp["isp"]),
            asn: asn(isp["asn"]),
            isProxy: bool(risk["is_proxy"]),
            isVPN: bool(risk["is_vpn"]),
            isTor: bool(risk["is_tor"]),
            isAbuser: bool(risk["is_abuser"]),
            source: "ipquery.io",
            checkedAt: .now
        )
    }

    static func parseIdentMe(_ data: Data) throws -> OutboundIPReport {
        let json = try object(from: data)
        return OutboundIPReport(
            ip: try validIP(json["ip"]),
            countryCode: countryCode(json["cc"]),
            country: text(json["country"]),
            kind: declaredKind(text(json["type"])) ?? .unknown,
            organization: text(json["aso"]),
            asn: asn(json["asn"]),
            source: "ident.me",
            checkedAt: .now
        )
    }

    static func parseIpWhoIs(_ data: Data) throws -> OutboundIPReport {
        let json = try object(from: data)
        guard json["success"] as? Bool != false else { throw ParseError() }
        let connection = object(json["connection"])
        let security = object(json["security"])
        return OutboundIPReport(
            ip: try validIP(json["ip"]),
            countryCode: countryCode(json["country_code"]),
            country: text(json["country"]),
            kind: kind(
                hosting: bool(security["hosting"]),
                mobile: false,
                declared: nil,
                inferResidential: false
            ),
            organization: text(connection["org"]) ?? text(connection["isp"]),
            asn: asn(connection["asn"]),
            isProxy: bool(security["proxy"]),
            isVPN: bool(security["vpn"]),
            isTor: bool(security["tor"]),
            isAbuser: bool(security["abuser"]),
            source: "ipwho.is",
            checkedAt: .now
        )
    }

    static func parseIpApiIs(_ data: Data) throws -> OutboundIPReport {
        let json = try object(from: data)
        return OutboundIPReport(
            ip: try validIP(json["ip"]),
            countryCode: nil,
            country: text(json["country"]),
            kind: kind(
                hosting: bool(json["is_datacenter"]),
                mobile: bool(json["is_mobile"]),
                declared: nil,
                inferResidential: false
            ),
            organization: text(json["company"]),
            asn: asn(json["asn"]),
            isProxy: bool(json["is_proxy"]),
            isVPN: bool(json["is_vpn"]),
            isTor: bool(json["is_tor"]),
            isAbuser: bool(json["is_abuser"]),
            source: "ipapi.is",
            checkedAt: .now
        )
    }

    // MARK: - Values

    private nonisolated enum SourceError: Error {
        case status(Int)
        case invalid
    }

    private static func kind(
        hosting: Bool,
        mobile: Bool,
        declared: String?,
        inferResidential: Bool
    ) -> OutboundIPReport.Kind {
        if hosting { return .hosting }
        if mobile { return .mobile }
        if let declared = declaredKind(declared) { return declared }
        return inferResidential ? .residential : .unknown
    }

    private static func declaredKind(_ value: String?) -> OutboundIPReport.Kind? {
        switch value?.lowercased() {
        case "residential", "isp": .residential
        case "mobile", "wireless", "cellular": .mobile
        case "business", "education", "government", "banking": .business
        case "hosting", "datacenter", "data center": .hosting
        default: nil
        }
    }

    private static func validIP(_ value: Any?) throws -> String {
        guard let ip = text(value),
              IPv4Address(ip) != nil || IPv6Address(ip) != nil else {
            throw ParseError()
        }
        return ip
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let dictionary = value as? [String: Any] else {
            throw ParseError()
        }
        return dictionary
    }

    private static func object(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func text(_ value: Any?) -> String? {
        let text: String?
        switch value {
        case let string as String: text = string
        case let number as NSNumber: text = number.stringValue
        default: text = nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func countryCode(_ value: Any?) -> String? {
        guard let code = text(value)?.uppercased(),
              code.count == 2,
              code.allSatisfy(\.isLetter) else { return nil }
        return code
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func asn(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            let asn = number.intValue
            return asn > 0 ? asn : nil
        case let text as String:
            let digits = text.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            guard let asn = Int(digits), asn > 0 else { return nil }
            return asn
        default:
            return nil
        }
    }

    private nonisolated struct ParseError: Error {}
}

// MARK: - Fetching

private extension OutboundIPSources.Source {
    func fetch(
        session: URLSession
    ) async -> Result<OutboundIPReport, OutboundIPFailure.SourceFailure> {
        do {
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            var request = URLRequest(
                url: url, timeoutInterval: OutboundIPSources.timeout
            )
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("LuckyClash/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OutboundIPSources.SourceError.invalid
            }
            guard (200...299).contains(http.statusCode) else {
                throw OutboundIPSources.SourceError.status(http.statusCode)
            }
            guard data.count <= OutboundIPSources.maximumBytes else {
                throw OutboundIPSources.SourceError.invalid
            }
            return .success(try parse(data))
        } catch is CancellationError {
            return .failure(.init(source: name, reason: "已取消"))
        } catch {
            return .failure(.init(source: name, reason: Self.reason(for: error)))
        }
    }

    private static func reason(for error: Error) -> String {
        if let error = error as? OutboundIPSources.SourceError {
            switch error {
            case .status(429): return "请求过多"
            case .status(let code): return "HTTP \(code)"
            case .invalid: return "返回格式无效"
            }
        }
        if let error = error as? URLError {
            return switch error.code {
            case .timedOut: "请求超时"
            case .notConnectedToInternet: "网络不可用"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "无法连接"
            default: "请求失败"
            }
        }
        return "返回格式无效"
    }
}

#if DEBUG
extension OutboundIPDetection {
    /// Seeds the card and sheet for SwiftUI previews without a network call.
    func seed(_ report: OutboundIPReport) {
        self.report = report
        failure = nil
        isChecking = false
        lastAttemptAt = .now
    }

    func seed(failure: OutboundIPFailure) {
        report = nil
        self.failure = failure
        isChecking = false
        lastAttemptAt = .now
    }

    static func preview(_ report: OutboundIPReport) -> OutboundIPDetection {
        let detection = OutboundIPDetection()
        detection.seed(report)
        return detection
    }

    static func preview(failure: OutboundIPFailure) -> OutboundIPDetection {
        let detection = OutboundIPDetection()
        detection.seed(failure: failure)
        return detection
    }
}
#endif
