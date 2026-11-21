import Foundation

struct ImportedNode: Identifiable {
    let name: String
    let type: String
    let endpoint: String
    let configuration: PrototypeConfiguration?

    var id: String { name }

    nonisolated init(
        name: String, type: String = "wireguard", endpoint: String,
        configuration: PrototypeConfiguration? = nil
    ) {
        self.name = name
        self.type = type
        self.endpoint = endpoint
        self.configuration = configuration
    }
}

struct ImportedConfiguration {
    var engine: Profile.Engine = .wireGuard
    let nodes: [ImportedNode]
    let rules: [RoutingRule]
    let warnings: [String]
    var clashYAML: String? = nil
    var groups: [ClashImportGroup] = []
}

enum ConfigurationImport {
    static let maximumFileSize = 32 * 1024
    static let maximumNodes = 16
    static let maximumRules = 128
    static let maximumRuleLines = 256
    static let maximumRuleLength = 512

    struct Invalid: LocalizedError {
        let location: String

        var errorDescription: String? { "配置无效或暂不支持（\(location)）。" }
    }

    private enum Section {
        case none
        case proxies
        case rules
        case ignored
    }

    private static let supportedFields: Set<String> = [
        "name", "type", "server", "port", "ip", "ipv6", "private-key", "public-key", "dns", "udp"
    ]

    private static let ignorableSections: Set<String> = [
        "proxy-groups", "rule-providers", "dns", "port", "socks-port", "mixed-port",
        "redir-port", "tproxy-port", "allow-lan", "bind-address", "mode", "log-level",
        "ipv6", "external-controller", "external-controller-cors", "secret", "profile",
        "experimental", "tun", "sniffer", "hosts", "unified-delay", "tcp-concurrent",
        "find-process-mode", "global-client-fingerprint", "geodata-mode", "geo-auto-update",
        "geox-url", "authentication", "listeners", "keep-alive-interval", "keep-alive-idle",
        "disable-keep-alive", "interface-name", "routing-mark", "geodata-loader", "geoip",
        "external-ui", "external-ui-name", "external-ui-url"
    ]

    static func parse(_ data: Data) throws -> ImportedConfiguration {
        guard data.count <= maximumFileSize else { throw Invalid(location: "文件大小上限 32 KB") }
        guard let decoded = String(data: data, encoding: .utf8) else { throw Invalid(location: "UTF-8 编码") }
        let source = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            let configuration = try PrototypeConfiguration.decode(data)
            return ImportedConfiguration(
                nodes: [ImportedNode(
                    name: "WireGuard", endpoint: configuration.endpoint,
                    configuration: configuration
                )],
                rules: [],
                warnings: []
            )
        }
        return try parseYAML(source)
    }

    private static func parseYAML(_ source: String) throws -> ImportedConfiguration {
        var section: Section = .none
        var fields: [String: String] = [:]
        var nodes: [ImportedNode] = []
        var names: Set<String> = []
        var rules: [RoutingRule] = []
        var warnings: [String] = []
        var ignoredSections: [String] = []
        var skippedRules = 0
        var rulesAfterMatch = 0
        var sawMatch = false
        var sawProxies = false
        var ruleLineCount = 0

        for (index, rawLine) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let indent = rawLine.prefix(while: { $0 == " " }).count
            let location = "第 \(index + 1) 行"

            if indent == 0 {
                if !fields.isEmpty {
                    try appendNode(fields, to: &nodes, names: &names)
                    fields.removeAll()
                }
                if line == "proxies:" {
                    section = .proxies
                    sawProxies = true
                    continue
                }
                if line == "rules:" {
                    section = .rules
                    continue
                }
                guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else {
                    throw Invalid(location: location)
                }
                let key = String(line[..<colon])
                guard ignorableSections.contains(key) else { throw Invalid(location: location) }
                if !ignoredSections.contains(key) { ignoredSections.append(key) }
                section = .ignored
                continue
            }

            switch section {
            case .none:
                throw Invalid(location: location)
            case .ignored:
                continue
            case .proxies:
                let entry: String
                if indent == 2, line.hasPrefix("- ") {
                    if !fields.isEmpty {
                        try appendNode(fields, to: &nodes, names: &names)
                        fields.removeAll()
                    }
                    guard nodes.count < maximumNodes else { throw Invalid(location: "节点数量上限 \(maximumNodes)") }
                    entry = String(line.dropFirst(2))
                } else {
                    guard indent == 4, !fields.isEmpty else { throw Invalid(location: location) }
                    entry = line
                }
                guard let colon = entry.firstIndex(of: ":") else { throw Invalid(location: location) }
                let key = String(entry[..<colon])
                let remainder = entry[entry.index(after: colon)...]
                guard supportedFields.contains(key), fields[key] == nil, remainder.first == " " else {
                    throw Invalid(location: supportedFields.contains(key) ? location + " · " + key : location)
                }
                let value = remainder.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { throw Invalid(location: location + " · " + key) }
                fields[key] = value
            case .rules:
                guard indent == 2, line.hasPrefix("- ") else { throw Invalid(location: location) }
                ruleLineCount += 1
                guard ruleLineCount <= maximumRuleLines else {
                    throw Invalid(location: "规则数量上限 \(maximumRuleLines)")
                }
                if sawMatch {
                    rulesAfterMatch += 1
                    continue
                }
                try parseRule(
                    String(line.dropFirst(2)), location: location,
                    rules: &rules, sawMatch: &sawMatch, skipped: &skippedRules
                )
            }
        }

        if !fields.isEmpty {
            try appendNode(fields, to: &nodes, names: &names)
        }
        guard sawProxies, !nodes.isEmpty else { throw Invalid(location: "proxies 至少包含一个节点") }

        if skippedRules > 0 {
            warnings.append("已忽略 \(skippedRules) 条不支持或无法应用的规则。")
        }
        if rulesAfterMatch > 0 {
            warnings.append("MATCH 之后的 \(rulesAfterMatch) 条规则已忽略。")
        }
        if !ignoredSections.isEmpty {
            warnings.append("已忽略不支持的 section：\(ignoredSections.joined(separator: "、"))。")
        }
        if !rules.isEmpty, !sawMatch {
            warnings.append("规则缺少 MATCH，规则模式默认将流量送入隧道。")
        }

        return ImportedConfiguration(nodes: nodes, rules: rules, warnings: warnings)
    }

    private static func parseRule(
        _ entry: String,
        location: String,
        rules: inout [RoutingRule],
        sawMatch: inout Bool,
        skipped: inout Int
    ) throws {
        guard entry.count <= maximumRuleLength else { throw Invalid(location: location + " · 规则长度") }
        let components = unquote(entry).split(separator: ",", omittingEmptySubsequences: false).map {
            unquote($0.trimmingCharacters(in: .whitespaces))
        }
        guard !components.contains(where: \.isEmpty) else { throw Invalid(location: location + " · 规则") }
        let type = components[0].uppercased()

        switch type {
        case "MATCH":
            guard components.count == 2 else { throw Invalid(location: location + " · MATCH") }
            sawMatch = true
            if isReject(components[1]) {
                skipped += 1
            } else {
                try appendRule(
                    RoutingRule(kind: .match, value: nil, policy: policy(components[1])),
                    to: &rules, location: location
                )
            }
        case "IP-CIDR", "IP-CIDR6":
            let expectsIPv4 = type == "IP-CIDR"
            guard components.count == 3
                    || (components.count == 4 && components[3].caseInsensitiveCompare("no-resolve") == .orderedSame) else {
                throw Invalid(location: location + " · 规则")
            }
            guard let prefix = IPPrefix(cidr: components[1]), prefix.isIPv4 == expectsIPv4 else {
                throw Invalid(location: location + " · 网段")
            }
            if isReject(components[2]) {
                skipped += 1
            } else {
                try appendRule(
                    RoutingRule(
                        kind: expectsIPv4 ? .ipv4 : .ipv6, value: prefix.cidr, policy: policy(components[2])
                    ),
                    to: &rules, location: location
                )
            }
        default:
            skipped += 1
        }
    }

    private static func appendRule(
        _ rule: RoutingRule, to rules: inout [RoutingRule], location: String
    ) throws {
        guard rules.count < maximumRules else { throw Invalid(location: "规则数量上限 \(maximumRules)") }
        rules.append(rule)
    }

    private static func policy(_ text: String) -> RoutingRule.Policy {
        text.caseInsensitiveCompare("direct") == .orderedSame ? .direct : .proxy
    }

    private static func isReject(_ text: String) -> Bool {
        text.caseInsensitiveCompare("reject") == .orderedSame
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }

    private static func appendNode(
        _ fields: [String: String], to nodes: inout [ImportedNode], names: inout Set<String>
    ) throws {
        let position = "节点 \(nodes.count + 1)"
        func value(_ key: String) throws -> String {
            guard let raw = fields[key], let value = scalar(raw) else {
                throw Invalid(location: position + " · " + key)
            }
            return value
        }

        let name = try value("name")
        guard name.count <= 80, names.insert(name).inserted else { throw Invalid(location: position + " · name") }
        guard try value("type") == "wireguard" else { throw Invalid(location: position + " · type") }
        if fields["udp"] != nil {
            guard try value("udp") == "true" else { throw Invalid(location: position + " · udp") }
        }
        guard let port = UInt16(try value("port")), port > 0 else { throw Invalid(location: position + " · port") }
        guard let dns = fields["dns"], dns.first == "[", dns.last == "]" else {
            throw Invalid(location: position + " · dns")
        }
        let dnsServers = dns.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
        let servers = try dnsServers.map { item in
            guard let server = scalar(item.trimmingCharacters(in: .whitespaces)) else {
                throw Invalid(location: position + " · dns")
            }
            return server
        }
        let configuration = try PrototypeConfiguration(
            endpointAddress: value("server"), endpointPort: port, clientIPv4: value("ip"),
            clientIPv6: value("ipv6"), dnsServers: servers, privateKey: value("private-key"),
            peerPublicKey: value("public-key")
        )
        do {
            try configuration.validate()
        } catch let error as PrototypeError.InvalidField {
            let yamlFields = [
                "endpointAddress": "server", "endpointPort": "port", "clientIPv4": "ip",
                "clientIPv6": "ipv6", "dnsServers": "dns", "privateKey": "private-key", "peerPublicKey": "public-key"
            ]
            throw Invalid(location: position + " · " + (yamlFields[error.name] ?? error.name))
        }
        nodes.append(ImportedNode(
            name: name, endpoint: configuration.endpoint, configuration: configuration
        ))
    }

    private static func scalar(_ raw: String) -> String? {
        let value: String
        guard let first = raw.first else { return nil }
        if first == "\"" || first == "'" {
            guard raw.count >= 2, first == raw.last else { return nil }
            value = String(raw.dropFirst().dropLast())
            guard !value.contains(first), !value.contains("\\") else { return nil }
        } else {
            guard !"!&*|>@`%?-".contains(first),
                  !raw.contains(where: { "[\\]{},#\"'".contains($0) }),
                  !raw.contains(": ") else { return nil }
            value = raw
        }
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespaces),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}
