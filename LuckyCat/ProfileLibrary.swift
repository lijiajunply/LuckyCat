import Foundation

struct Profile: Codable, Identifiable {
    struct Node: Codable, Identifiable {
        let id: UUID // Immutable snapshot revision.
        let name: String
        let endpoint: String
        var clientIPv4: String? = nil
        var clientIPv6: String? = nil
        var dnsServers: [String]? = nil

        var compatibilityNotes: [String] {
            guard let clientIPv4, let clientIPv6 else {
                return [
                    "此节点由早期版本导入，未保存双栈地址信息。",
                    "可使用当前选中的节点连接；重新导入可获得完整兼容提示。"
                ]
            }
            var notes = [
                "双栈默认路由：\(clientIPv4) / \(clientIPv6)。",
                "远端地址和 iOS 系统例外走普通网络。",
                "断开后 iOS 可能恢复普通网络访问。"
            ]
            if let dnsServers, !dnsServers.isEmpty {
                notes.append("隧道内 DNS：\(dnsServers.joined(separator: ", "))。DNS 须可从隧道内访问。")
            }
            return notes
        }
    }

    let id: UUID
    let name: String
    let nodes: [Node]
    var selectedNodeID: UUID
    var sourceURL: URL? = nil
    var rules: [RoutingRule]? = nil

    var selectedNode: Node? { nodes.first { $0.id == selectedNodeID } }
}

struct ProfileLibrary: Codable {
    var profiles: [Profile] = []
    var selectedProfileID: UUID?
    var mode: TrafficMode? = nil

    var selectedProfile: Profile? { profiles.first { $0.id == selectedProfileID } }

    var trafficMode: TrafficMode { mode ?? .global }

    static func load() throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "Profiles.json")
}
