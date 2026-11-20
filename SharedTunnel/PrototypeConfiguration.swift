import Foundation
import Network
import Security

struct PrototypeConfiguration: Codable {
    static let maximumFileSize = 8 * 1024
    static let mtu = 1280

    let endpointAddress: String
    let endpointPort: UInt16
    let clientIPv4: String
    let clientIPv6: String
    let dnsServers: [String]
    let privateKey: String
    let peerPublicKey: String

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileSize else { throw PrototypeError.invalidField("文件大小（上限 8 KB）") }
        let configuration: Self
        do {
            configuration = try JSONDecoder().decode(Self.self, from: data)
        } catch let error as DecodingError {
            switch error {
            case .keyNotFound(let key, _):
                throw PrototypeError.invalidField(key.stringValue)
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                throw PrototypeError.invalidField(context.codingPath.last?.stringValue ?? "JSON")
            @unknown default:
                throw PrototypeError.invalidField("JSON")
            }
        }
        try configuration.validate()
        return configuration
    }

    var endpoint: String {
        let host = IPv6Address(endpointAddress) == nil ? endpointAddress : "[\(endpointAddress)]"
        return "\(host):\(endpointPort)"
    }

    func wireGuardSettings() throws -> String {
        [
            "private_key=\(try Self.hexKey(privateKey, field: "privateKey"))",
            "replace_peers=true",
            "public_key=\(try Self.hexKey(peerPublicKey, field: "peerPublicKey"))",
            "endpoint=\(endpoint)",
            "persistent_keepalive_interval=10",
            "replace_allowed_ips=true",
            "allowed_ip=0.0.0.0/0",
            "allowed_ip=::/0",
            ""
        ].joined(separator: "\n")
    }

    func validate() throws {
        guard Self.isIP(endpointAddress),
              !endpointAddress.contains("%") else {
            throw PrototypeError.invalidField("endpointAddress")
        }
        guard endpointPort > 0 else { throw PrototypeError.invalidField("endpointPort") }
        guard Self.isIP(clientIPv4), let ipv4 = IPv4Address(clientIPv4),
              ipv4 != IPv4Address(endpointAddress) else {
            throw PrototypeError.invalidField("clientIPv4")
        }
        guard Self.isIP(clientIPv6), let ipv6 = IPv6Address(clientIPv6),
              !clientIPv6.contains("%"), ipv6 != IPv6Address(endpointAddress) else {
            throw PrototypeError.invalidField("clientIPv6")
        }
        guard (1...3).contains(dnsServers.count),
              dnsServers.allSatisfy({ Self.isIP($0) && !$0.contains("%") }),
              !dnsServers.contains(where: {
                  if let server = IPv4Address($0) { return server == IPv4Address(endpointAddress) }
                  return IPv6Address($0) == IPv6Address(endpointAddress)
              }) else {
            throw PrototypeError.invalidField("dnsServers")
        }
        _ = try wireGuardSettings()
    }

    private static func isIP(_ address: String) -> Bool {
        if let ipv4 = IPv4Address(address) {
            return !ipv4.isLoopback && ipv4 != .any && ipv4 != .broadcast && !ipv4.isMulticast
        }
        if let ipv6 = IPv6Address(address) {
            return !ipv6.isLoopback && ipv6 != .any && !ipv6.isLinkLocal && !ipv6.isMulticast && !ipv6.isIPv4Mapped
        }
        return false
    }

    private static func hexKey(_ key: String, field: String) throws -> String {
        guard let decoded = Data(base64Encoded: key), decoded.count == 32,
              decoded.contains(where: { $0 != 0 }) else {
            throw PrototypeError.invalidField(field)
        }
        return decoded.map { String(format: "%02x", $0) }.joined()
    }
}

enum PrototypeError: Int, Error, CustomNSError, LocalizedError {
    case missingConfiguration = 1
    case keychainUnavailable
    case engineStartup
    case networkSettings
    case handshakeTimeout
    case startCancelled
    case duplicateConfiguration
    case simulator
    case sharedContainerUnavailable
    case activeConfiguration
    case profileStorage
    case invalidRulePlan

    static let errorDomain = "com.luckyfish.LuckyCat.Tunnel"
    var errorCode: Int { rawValue }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "找不到测试配置，请重新导入。"
        case .keychainUnavailable: "无法读写共享钥匙串，请核对签名和设备解锁状态。"
        case .engineStartup: "WireGuard 启动失败，请核对测试配置。"
        case .networkSettings: "iOS 无法应用隧道网络设置。"
        case .handshakeTimeout: "WireGuard 握手超时，请核对远端地址、UDP 端口和密钥。"
        case .startCancelled: "连接启动已取消。"
        case .duplicateConfiguration: "发现多个 LuckyCat VPN 配置，请在系统设置中保留一个。"
        case .sharedContainerUnavailable: "无法打开共享配置目录，请核对 App Group 签名。"
        case .activeConfiguration: "请先断开 VPN，然后再删除配置。"
        case .profileStorage: "无法读写本地配置，请检查设备存储后重试。"
        case .invalidRulePlan: "规则生成的网段过多或无效，请精简规则后重试。"
        case .simulator: "请在 iPhone 真机上验证 VPN 连接。"
        }
    }

    struct InvalidField: LocalizedError {
        let name: String
        var errorDescription: String? { "测试配置字段无效或缺失（\(name)）。" }
    }

    static func invalidField(_ name: String) -> InvalidField {
        InvalidField(name: name)
    }
}

enum PrototypeStore {
    static let revisionKey = "prototypeRevision"
    static let configurationIdentifierKey = "configurationIdentifier"
    static let configurationIdentifier = "wireguard-baseline-v1"
    private static let service = "com.luckyfish.LuckyCat.WireGuardPrototype"

    static func save<Value: Encodable>(_ value: Value, revision: UUID) throws {
        var attributes = try query(for: revision)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = try JSONEncoder().encode(value)
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw PrototypeError.keychainUnavailable
        }
    }

    static func load(revision: UUID) throws -> PrototypeConfiguration {
        try PrototypeConfiguration.decode(data(for: revision))
    }

    static func data(for revision: UUID) throws -> Data {
        var attributes = try query(for: revision)
        attributes[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        if status == errSecItemNotFound { throw PrototypeError.missingConfiguration }
        guard status == errSecSuccess, let data = item as? Data else { throw PrototypeError.keychainUnavailable }
        return data
    }

    static func remove(revision: UUID) {
        guard let attributes = try? query(for: revision) else { return }
        SecItemDelete(attributes as CFDictionary)
    }

    private static func query(for revision: UUID) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PrototypeKeychainGroup") as? String,
              !group.isEmpty else { throw PrototypeError.keychainUnavailable }
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: revision.uuidString
        ]
        #if !targetEnvironment(simulator)
        attributes[kSecAttrAccessGroup as String] = group
        #endif
        return attributes
    }
}
