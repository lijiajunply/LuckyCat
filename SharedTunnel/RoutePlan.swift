import Darwin
import Foundation

struct RoutingRule: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ipv4
        case ipv6
        case match
    }

    enum Policy: String, Codable, Sendable {
        case proxy
        case direct
    }

    let kind: Kind
    let value: String?
    let policy: Policy
}

struct IPPrefix: Codable, Hashable, Sendable {
    static let maximumRouteCount = 128

    let address: String
    let prefixLength: Int

    init(address: String, prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }

    init?(cidr: String) {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              let length = Int(parts[1]),
              let family = PrefixValue.family(of: String(parts[0])),
              (0...(family == .v4 ? 32 : 128)).contains(length),
              let bytes = PrefixValue.parse(String(parts[0]), family: family) else {
            return nil
        }
        var normalized = bytes
        PrefixValue.mask(&normalized, length: length)
        self.init(value: PrefixValue(family: family, bytes: normalized, length: length))
    }

    fileprivate init(value: PrefixValue) {
        address = PrefixValue.format(value) ?? "0.0.0.0"
        prefixLength = value.length
    }

    var cidr: String { "\(address)/\(prefixLength)" }

    var isIPv4: Bool { !address.contains(":") }

    fileprivate var value: PrefixValue? {
        guard let family = PrefixValue.family(of: address),
              (0...(family == .v4 ? 32 : 128)).contains(prefixLength),
              let bytes = PrefixValue.parse(address, family: family) else {
            return nil
        }
        var normalized = bytes
        PrefixValue.mask(&normalized, length: prefixLength)
        return PrefixValue(family: family, bytes: normalized, length: prefixLength)
    }

    static func sorted(_ prefixes: [IPPrefix]) -> [IPPrefix] {
        prefixes.sorted {
            ($0.prefixLength, $0.address) < ($1.prefixLength, $1.address)
        }
    }
}

struct RoutePlan: Codable, Equatable, Sendable {
    let mode: TrafficMode
    let ipv4Included: [IPPrefix]
    let ipv4Excluded: [IPPrefix]
    let ipv6Included: [IPPrefix]
    let ipv6Excluded: [IPPrefix]
    let usesTunnelDNS: Bool

    static let global = RoutePlan(
        mode: .global,
        ipv4Included: [IPPrefix(address: "0.0.0.0", prefixLength: 0)],
        ipv4Excluded: [],
        ipv6Included: [IPPrefix(address: "::", prefixLength: 0)],
        ipv6Excluded: [],
        usesTunnelDNS: true
    )

    static let direct = RoutePlan(
        mode: .direct,
        ipv4Included: [],
        ipv4Excluded: [],
        ipv6Included: [],
        ipv6Excluded: [],
        usesTunnelDNS: false
    )

    static func make(mode: TrafficMode, rules: [RoutingRule]) throws -> RoutePlan {
        switch mode {
        case .global:
            return .global
        case .direct:
            return .direct
        case .rule:
            return try makeRulePlan(rules)
        }
    }

    private static func makeRulePlan(_ rules: [RoutingRule]) throws -> RoutePlan {
        var defaultProxy = true
        var sawMatch = false
        var proxy: [PrefixValue] = []
        var direct: [PrefixValue] = []

        for rule in rules {
            switch rule.kind {
            case .match:
                guard !sawMatch else { continue }
                sawMatch = true
                defaultProxy = rule.policy == .proxy
            case .ipv4, .ipv6:
                guard !sawMatch, let text = rule.value, let prefix = IPPrefix(cidr: text)?.value else { continue }
                guard (rule.kind == .ipv4) == (prefix.family == .v4) else { continue }
                let parts = subtractAll(prefix, excluding: proxy + direct)
                if rule.policy == .proxy {
                    proxy.append(contentsOf: parts)
                } else {
                    direct.append(contentsOf: parts)
                }
            }
        }

        let proxyIPv4 = Self.prefixes(proxy, family: .v4)
        let proxyIPv6 = Self.prefixes(proxy, family: .v6)
        let directIPv4 = Self.prefixes(direct, family: .v4)
        let directIPv6 = Self.prefixes(direct, family: .v6)

        // Rules that only ever match DIRECT are equivalent to direct mode.
        if !defaultProxy, proxyIPv4.isEmpty, proxyIPv6.isEmpty {
            return .direct
        }

        let includedIPv4 = defaultProxy
            ? [IPPrefix(address: "0.0.0.0", prefixLength: 0)]
            : proxyIPv4
        let includedIPv6 = defaultProxy
            ? [IPPrefix(address: "::", prefixLength: 0)]
            : proxyIPv6
        let excludedIPv4 = defaultProxy ? directIPv4 : []
        let excludedIPv6 = defaultProxy ? directIPv6 : []

        guard includedIPv4.count <= IPPrefix.maximumRouteCount,
              includedIPv6.count <= IPPrefix.maximumRouteCount,
              excludedIPv4.count <= IPPrefix.maximumRouteCount,
              excludedIPv6.count <= IPPrefix.maximumRouteCount else {
            throw PrototypeError.invalidRulePlan
        }

        return RoutePlan(
            mode: .rule,
            ipv4Included: IPPrefix.sorted(includedIPv4),
            ipv4Excluded: IPPrefix.sorted(excludedIPv4),
            ipv6Included: IPPrefix.sorted(includedIPv6),
            ipv6Excluded: IPPrefix.sorted(excludedIPv6),
            usesTunnelDNS: defaultProxy
        )
    }

    private static func prefixes(_ values: [PrefixValue], family: PrefixFamily) -> [IPPrefix] {
        values.filter { $0.family == family }.map(IPPrefix.init(value:))
    }

    /// Returns the portions of `prefix` not covered by any of `existing`.
    private static func subtractAll(_ prefix: PrefixValue, excluding existing: [PrefixValue]) -> [PrefixValue] {
        var parts = [prefix]
        for excluded in existing where !parts.isEmpty {
            parts = parts.flatMap { subtract($0, excluding: excluded) }
        }
        return parts
    }

    private static func subtract(_ prefix: PrefixValue, excluding other: PrefixValue) -> [PrefixValue] {
        guard prefix.family == other.family else { return [prefix] }
        if other.contains(prefix) { return [] }
        guard prefix.contains(other), other.length > prefix.length else { return [prefix] }

        var result: [PrefixValue] = []
        var current = prefix.bytes
        for depth in prefix.length..<other.length {
            let otherBit = other.bit(at: depth)
            var sibling = current
            PrefixValue.setBit(&sibling, at: depth, to: !otherBit)
            result.append(PrefixValue(family: prefix.family, bytes: sibling, length: depth + 1))
            PrefixValue.setBit(&current, at: depth, to: otherBit)
        }
        return result
    }
}

private enum PrefixFamily {
    case v4
    case v6

    var bitCount: Int {
        switch self {
        case .v4: 32
        case .v6: 128
        }
    }
}

private struct PrefixValue: Hashable {
    let family: PrefixFamily
    let bytes: [UInt8]
    let length: Int

    var bitCount: Int { family.bitCount }

    func contains(_ other: PrefixValue) -> Bool {
        guard family == other.family, length <= other.length else { return false }
        for index in 0..<length where bit(at: index) != other.bit(at: index) {
            return false
        }
        return true
    }

    func bit(at index: Int) -> Bool {
        (bytes[index / 8] >> (7 - index % 8)) & 1 == 1
    }

    static func setBit(_ bytes: inout [UInt8], at index: Int, to value: Bool) {
        let mask: UInt8 = 1 << (7 - index % 8)
        if value {
            bytes[index / 8] |= mask
        } else {
            bytes[index / 8] &= ~mask
        }
    }

    static func mask(_ bytes: inout [UInt8], length: Int) {
        for index in bytes.indices {
            let bits = min(max(length - index * 8, 0), 8)
            if bits == 0 {
                bytes[index] = 0
            } else if bits < 8 {
                bytes[index] &= UInt8((0xFF << (8 - bits)) & 0xFF)
            }
        }
    }

    static func family(of text: String) -> PrefixFamily? {
        if parse(text, family: .v4) != nil { return .v4 }
        if parse(text, family: .v6) != nil { return .v6 }
        return nil
    }

    static func parse(_ text: String, family: PrefixFamily) -> [UInt8]? {
        switch family {
        case .v4:
            var address = in_addr()
            guard text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
            return withUnsafeBytes(of: &address) { Array($0) }
        case .v6:
            var address = in6_addr()
            guard text.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            return withUnsafeBytes(of: &address) { Array($0) }
        }
    }

    static func format(_ value: PrefixValue) -> String? {
        var bytes = value.bytes
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = value.family == .v4 ? AF_INET : AF_INET6
        let formatted = bytes.withUnsafeMutableBytes { buffer in
            inet_ntop(family, buffer.baseAddress, &output, socklen_t(INET6_ADDRSTRLEN))
        }
        guard formatted != nil else { return nil }
        return String(cString: output)
    }
}
