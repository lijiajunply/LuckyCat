import Foundation

nonisolated enum TunnelNetworkOptions {
    static let ipv6Mode = "tunIPv6Mode"
    static let queryMode = "ipQueryMode"
    static let mtu = "tunMTU"
    static let includeAllNetworks = "includeAllNetworks"
    static let bypassPrivate = "bypassPrivateAddresses"
    static let statisticsProxyOnly = "onlyStatisticsProxy"
    static let onDemand = "onDemandEnabled"
    static let excludedSSIDs = "onDemandExcludedSSIDs"

    static var trustedSSIDs: [String] {
        let value = UserDefaults.standard.string(forKey: excludedSSIDs) ?? ""
        var seen: Set<String> = []
        return value.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty && $0.utf8.count <= 32 && seen.insert($0).inserted }
    }
}
