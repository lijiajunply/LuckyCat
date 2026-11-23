import Clash
import Foundation

struct ClashImportGroup: Codable, Equatable {
    let name: String
    let type: String
    let members: [String]
    /// The `url` / `test-url` used by url-test style groups. Delay tests prefer
    /// it over the built-in fallback because it is reachable through the
    /// profile's own network conditions.
    var testURL: String? = nil

    nonisolated var isSelectable: Bool { type.caseInsensitiveCompare("select") == .orderedSame }
}

/// Turns anything a FlClash-style subscription URL can return into a single
/// Clash configuration: a Clash YAML file, a base64 share-link bundle, or one
/// or more proxy share links. Parsing and link conversion happen in the pinned
/// Clash core so the accepted protocol set matches the tunnel core.
enum ClashImport {
    nonisolated static let maximumBytes = RemoteImport.maximumBytes
    nonisolated static let maximumNodes = 4096
    nonisolated private static let defaultDNS = ["223.5.5.5", "119.29.29.29"]
    nonisolated private static let generatedGroupName = "LuckyClash"

    enum Failure: LocalizedError, Equatable {
        case tooLarge
        case empty
        case unreadable
        case noProxies(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: "配置内容超过 \(maximumBytes / 1024 / 1024) MB 上限。"
            case .empty: "配置内容为空。"
            case .unreadable: "无法解析该配置。请确认链接返回的是 Clash 配置、订阅或分享链接。"
            case .noProxies(let detail):
                detail.isEmpty ? "配置中没有可用的节点。" : "配置中没有可用的节点（\(detail)）。"
            }
        }
    }

    nonisolated static func parse(_ data: Data) throws -> ImportedConfiguration {
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= maximumBytes else { throw Failure.tooLarge }

        var yamlError: NSError?
        if let text = String(data: data, encoding: .utf8),
           let configuration = try parseConfiguration(text, error: &yamlError) {
            return configuration
        }

        var conversionError: NSError?
        if let box = ClashConvertProxiesForIOS(data, &conversionError) {
            return try parseConfiguration(box.value, format: .links)
        }

        // Some panels base64-encode the whole document rather than a link list.
        if let decoded = decodedBase64(data),
           let text = String(data: decoded, encoding: .utf8),
           let configuration = try parseConfiguration(text, error: &conversionError) {
            return configuration
        }

        let detail = conversionError?.localizedDescription ?? yamlError?.localizedDescription ?? ""
        if detail.isEmpty {
            throw Failure.unreadable
        }
        throw Failure.noProxies(detail)
    }

    /// Converts the legacy WireGuard parser output into a Clash configuration so
    /// every saved profile runs through the single Clash core in the extension.
    nonisolated static func fromLegacy(_ configuration: ImportedConfiguration) throws -> ImportedConfiguration {
        var proxies: [[String: Any]] = []
        var nodes: [ImportedNode] = []
        for node in configuration.nodes {
            guard let value = node.configuration else { continue }
            proxies.append([
                "name": node.name,
                "type": "wireguard",
                "server": value.endpointAddress,
                "port": Int(value.endpointPort),
                "ip": value.clientIPv4,
                "ipv6": value.clientIPv6,
                "private-key": value.privateKey,
                "public-key": value.peerPublicKey,
                "dns": value.dnsServers,
                "udp": true,
                "mtu": 1280
            ])
            nodes.append(ImportedNode(
                name: node.name, type: "wireguard", endpoint: node.endpoint,
                configuration: value
            ))
        }
        guard !proxies.isEmpty else { throw Failure.noProxies("") }

        let names = proxies.compactMap { $0["name"] as? String }
        var rules = configuration.rules.compactMap { rule -> String? in
            let policy = rule.policy == .direct ? "DIRECT" : generatedGroupName
            switch rule.kind {
            case .ipv4:
                return rule.value.map { "IP-CIDR,\($0),\(policy)" }
            case .ipv6:
                return rule.value.map { "IP-CIDR6,\($0),\(policy)" }
            case .match:
                return "MATCH,\(policy)"
            }
        }
        if !configuration.rules.contains(where: { $0.kind == .match }) {
            rules.append("MATCH,\(generatedGroupName)")
        }
        let document: [String: Any] = [
            "mode": "rule",
            "geodata-mode": true,
            "dns": [
                "enable": true,
                "ipv6": false,
                "enhanced-mode": "fake-ip",
                "fake-ip-range": "198.18.0.1/16",
                "nameserver": defaultDNS
            ],
            "proxies": proxies,
            "proxy-groups": [[
                "name": generatedGroupName, "type": "select", "proxies": names
            ]],
            "rules": rules
        ]
        let yaml = try encodeYAML(document)
        return ImportedConfiguration(
            engine: .clash,
            nodes: nodes,
            rules: [],
            warnings: configuration.warnings + (configuration.rules.isEmpty
                ? ["配置没有分流规则，规则模式下所有流量将使用代理。"] : []),
            clashYAML: yaml,
            groups: [ClashImportGroup(
                name: generatedGroupName, type: "select", members: names
            )]
        )
    }

    // MARK: - Configuration documents

    private enum Format {
        case config
        case links
    }

    nonisolated private static func parseConfiguration(
        _ raw: String, error yamlError: inout NSError?
    ) throws -> ImportedConfiguration? {
        let text = normalized(raw)
        guard !text.isEmpty else { return nil }
        guard let box = ClashYamlToJSON(text, &yamlError),
              let data = box.value.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard isConfiguration(document) else { return nil }
        return try make(document: document, text: text, format: .config)
    }

    nonisolated private static func parseConfiguration(
        _ proxiesYAML: String, format: Format
    ) throws -> ImportedConfiguration {
        guard let box = ClashYamlToJSON(proxiesYAML, nil),
              let data = box.value.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        return try make(document: document, text: proxiesYAML, format: format)
    }

    nonisolated private static func isConfiguration(_ document: [String: Any]) -> Bool {
        ["proxies", "proxy-providers", "proxy-groups", "rules"].contains { key in
            guard let value = document[key] else { return false }
            if let list = value as? [Any] { return !list.isEmpty }
            if let map = value as? [String: Any] { return !map.isEmpty }
            return true
        }
    }

    nonisolated private static func make(
        document: [String: Any], text: String, format: Format
    ) throws -> ImportedConfiguration {
        var document = document
        var warnings: [String] = []

        let proxies = document["proxies"] as? [[String: Any]] ?? []
        let providerNames = (document["proxy-providers"] as? [String: Any])?.keys.sorted() ?? []
        let groups = (document["proxy-groups"] as? [[String: Any]] ?? []).compactMap(groupInfo)
        let rules = document["rules"] as? [Any] ?? []

        if !providerNames.isEmpty {
            warnings.append("配置使用 proxy-providers，首次连接时由内核下载节点。")
        }
        if document["rule-providers"] != nil {
            warnings.append("配置使用 rule-providers，规则集可能需要联网加载。")
        }
        if proxies.count > maximumNodes {
            warnings.append("节点数量超过 \(maximumNodes) 个，界面只显示前 \(maximumNodes) 个。")
        }
        if proxies.isEmpty, providerNames.isEmpty {
            throw Failure.noProxies("")
        }

        let nodes = proxies.prefix(maximumNodes).compactMap(nodeInfo)

        let hasGroups = !groups.isEmpty
        let hasRules = !rules.isEmpty
        let needsWrapper = !hasRules && !hasGroups
        if !hasRules {
            warnings.append("配置没有分流规则，规则模式下所有流量将使用默认策略组，可能与全局模式相同。")
        }
        if needsWrapper {
            let group: [String: Any]
            if proxies.isEmpty {
                group = [
                    "name": generatedGroupName, "type": "select",
                    "use": providerNames, "proxies": ["DIRECT"]
                ]
            } else {
                let names = proxies.compactMap { $0["name"] as? String }
                group = [
                    "name": generatedGroupName, "type": "select",
                    "proxies": names + ["DIRECT"]
                ]
            }
            document["proxy-groups"] = [group]
            document["rules"] = ["MATCH,\(generatedGroupName)"]
            document["mode"] = document["mode"] ?? "rule"
        } else if !hasRules, hasGroups {
            let target = groups.first(where: \.isSelectable)?.name ?? groups[0].name
            document["rules"] = ["MATCH,\(target)"]
            document["mode"] = document["mode"] ?? "rule"
        }

        let dnsChanged = ensureDNS(&document)
        // The app stages `.dat` files, so the core must read GeoIP.dat and
        // GeoSite.dat rather than downloading an MMDB while the tunnel starts.
        let geodataModeChanged = (document["geodata-mode"] as? Bool) != true
        if geodataModeChanged {
            document["geodata-mode"] = true
        }

        var yaml = text
        if needsWrapper || !hasRules || dnsChanged || geodataModeChanged {
            yaml = try encodeYAML(document)
        }

        var importedGroups = groups
        if needsWrapper {
            let names = proxies.compactMap { $0["name"] as? String }
            importedGroups = [ClashImportGroup(
                name: generatedGroupName, type: "select",
                members: proxies.isEmpty ? providerNames : names + ["DIRECT"]
            )]
        }

        return ImportedConfiguration(
            engine: .clash,
            nodes: nodes,
            rules: [],
            warnings: warnings,
            clashYAML: yaml,
            groups: importedGroups
        )
    }

    nonisolated private static func ensureDNS(_ document: inout [String: Any]) -> Bool {
        var dns = document["dns"] as? [String: Any] ?? [:]
        var changed = false
        if (dns["enable"] as? Bool) != true {
            dns["enable"] = true
            changed = true
        }
        if (dns["nameserver"] as? [Any])?.isEmpty != false {
            dns["nameserver"] = defaultDNS
            changed = true
        }
        if dns["enhanced-mode"] == nil {
            dns["enhanced-mode"] = "fake-ip"
            changed = true
        }
        if (dns["enhanced-mode"] as? String) == "fake-ip", dns["fake-ip-range"] == nil {
            dns["fake-ip-range"] = "198.18.0.1/16"
            changed = true
        }
        if changed {
            document["dns"] = dns
        }
        return changed
    }

    nonisolated private static func nodeInfo(_ raw: [String: Any]) -> ImportedNode? {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let type = raw["type"] as? String ?? "unknown"
        let server = raw["server"] as? String
        let port = (raw["port"] as? NSNumber)?.intValue
            ?? (raw["port"] as? String).flatMap(Int.init)
        var endpoint = server ?? ""
        if let server, let port, port > 0 {
            let host = server.contains(":") && !server.hasPrefix("[") ? "[\(server)]" : server
            endpoint = "\(host):\(port)"
        }
        return ImportedNode(name: name, type: type, endpoint: endpoint, configuration: nil)
    }

    nonisolated private static func groupInfo(_ raw: [String: Any]) -> ClashImportGroup? {
        guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
        let type = raw["type"] as? String ?? "select"
        var members = raw["proxies"] as? [String] ?? []
        if members.isEmpty {
            members = raw["use"] as? [String] ?? []
        }
        let testURL = ((raw["url"] as? String) ?? (raw["test-url"] as? String))
            .flatMap { $0.isEmpty ? nil : $0 }
        return ClashImportGroup(
            name: name, type: type, members: members, testURL: testURL
        )
    }

    nonisolated private static func encodeYAML(_ document: [String: Any]) throws -> String {
        var error: NSError?
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let box = ClashJSONToYaml(String(decoding: data, as: UTF8.self), &error) else {
            throw Failure.unreadable
        }
        return box.value
    }

    nonisolated private static func decodedBase64(_ data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let decoded = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]),
              !decoded.isEmpty, decoded != data else {
            return nil
        }
        return decoded
    }

    nonisolated private static func normalized(_ raw: String) -> String {
        var text = raw
        if text.hasPrefix("\u{FEFF}") {
            text = String(text.dropFirst())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
