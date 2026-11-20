import Foundation

struct ImportedNode: Identifiable {
    let name: String
    let configuration: PrototypeConfiguration

    var id: String { name }
}

enum ConfigurationImport {
    static let maximumFileSize = 32 * 1024

    struct Invalid: LocalizedError {
        let location: String

        var errorDescription: String? { "配置无效或暂不支持（\(location)）。" }
    }

    static func parse(_ data: Data) throws -> [ImportedNode] {
        guard data.count <= maximumFileSize else { throw Invalid(location: "文件大小上限 32 KB") }
        guard let decoded = String(data: data, encoding: .utf8) else { throw Invalid(location: "UTF-8 编码") }
        let source = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return [ImportedNode(name: "WireGuard", configuration: try PrototypeConfiguration.decode(data))]
        }

        // A fixed-depth YAML subset for standalone WireGuard proxy lists.
        let supportedFields: Set<String> = [
            "name", "type", "server", "port", "ip", "ipv6", "private-key", "public-key", "dns", "udp"
        ]
        var hasRoot = false
        var fields: [String: String] = [:]
        var nodes: [ImportedNode] = []
        var names: Set<String> = []
        for (index, rawLine) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let indent = rawLine.prefix(while: { $0 == " " }).count
            let location = "第 \(index + 1) 行"
            if !hasRoot {
                guard indent == 0, line == "proxies:" else { throw Invalid(location: location + " · proxies") }
                hasRoot = true
                continue
            }
            let entry: String
            if indent == 2, line.hasPrefix("- ") {
                if !fields.isEmpty {
                    try appendNode(fields, to: &nodes, names: &names)
                    fields.removeAll()
                }
                guard nodes.count < 16 else { throw Invalid(location: "节点数量上限 16") }
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
        }
        guard !fields.isEmpty else { throw Invalid(location: "proxies 至少包含一个节点") }
        try appendNode(fields, to: &nodes, names: &names)
        return nodes
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
        nodes.append(ImportedNode(name: name, configuration: configuration))
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
