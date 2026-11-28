import Foundation

nonisolated struct ConfigurationOverrides: Codable, Equatable, Sendable {
    enum DNSMode: String, CaseIterable, Codable, Sendable {
        case fakeIP = "fake-ip"
        case redirHost = "redir-host"
    }

    var dnsMode: DNSMode?
    var nameservers: [String]?
    var fallback: [String]?
    var fakeIPFilter: [String]?
    var dnsRespectRules: Bool?
    var dnsIPv6: Bool?
    var hosts: [String: String]?
    var logLevel: String?
    var sniffer: Bool?
    var ntp: Bool?
    var prependRules: [String] = []
    var appendRules: [String] = []

    static let empty = Self()

    var patch: [String: Any] {
        var dns: [String: Any] = [:]
        dns["enhanced-mode"] = dnsMode?.rawValue
        dns["nameserver"] = nameservers
        dns["fallback"] = fallback
        dns["fake-ip-filter"] = fakeIPFilter
        dns["respect-rules"] = dnsRespectRules
        dns["ipv6"] = dnsIPv6
        var patch: [String: Any] = [:]
        if !dns.isEmpty { patch["dns"] = dns }
        patch["hosts"] = hosts
        patch["log-level"] = logLevel
        if let sniffer { patch["sniffer"] = ["enable": sniffer] }
        if let ntp { patch["ntp"] = ["enable": ntp] }
        return patch
    }
}
