import Foundation

struct Profile: Codable, Identifiable {
    enum Engine: String, Codable {
        case wireGuard = "wireguard"
        case clash
    }

    struct Subscription: Codable, Equatable {
        nonisolated init() {}

        var upload: UInt64?
        var download: UInt64?
        var total: UInt64?
        var expire: Date?
        var updateIntervalHours: Int?
        var webPageURL: String?
        var lastUpdated: Date?
    }

    struct Node: Codable, Identifiable {
        let id: UUID // Immutable snapshot revision.
        let name: String
        let endpoint: String
        var type: String? = nil
        var clientIPv4: String? = nil
        var clientIPv6: String? = nil
        var dnsServers: [String]? = nil

        var compatibilityNotes: [String] {
            if let type, clientIPv4 == nil {
                return [
                    "协议：\(type)。",
                    "由 Clash 内核按配置中的策略组和规则分流。",
                    "断开后 iOS 可能恢复普通网络访问。"
                ]
            }
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
    var name: String
    let nodes: [Node]
    var selectedNodeID: UUID
    var sourceURL: URL? = nil
    var rules: [RoutingRule]? = nil
    var engine: Engine? = nil
    var clashRevision: UUID? = nil
    var clashGroup: String? = nil
    var clashGroups: [ClashImportGroup]? = nil
    var subscription: Subscription? = nil
    var autoUpdate: Bool? = nil
    var clashSelectedMember: String? = nil
    var updateIntervalOverrideHours: Int? = nil
    var clashSelections: [String: String]? = nil
    var overrides: ConfigurationOverrides? = nil
    var effectiveRevision: UUID? = nil
    var customRecipe: CustomProfileRecipe? = nil

    var selectedNode: Node? { nodes.first { $0.id == selectedNodeID } }
    var selectedOutboundName: String? { clashSelectedMember ?? selectedNode?.name }
    var globalTarget: String? {
        if let clashGroup, clashGroups?.contains(where: { $0.name == clashGroup && $0.canPin }) == true {
            return groupSelections[clashGroup] ?? clashGroup
        }
        return clashSelectedMember ?? selectedNode.flatMap { $0.type == "auto" ? nil : $0.name }
    }
    var groupSelections: [String: String] {
        if let clashSelections { return clashSelections }
        guard let clashGroup, !clashGroup.isEmpty,
              let member = clashSelectedMember ?? selectedNode.flatMap({ $0.type == "auto" ? nil : $0.name }),
              !member.isEmpty else { return [:] }
        return [clashGroup: member]
    }

    mutating func selectGroup(_ group: String, member: String?) {
        var selections = groupSelections
        selections[group] = member
        clashSelections = selections
        if let member {
            clashGroup = group
            if let node = nodes.first(where: { $0.name == member }) {
                selectedNodeID = node.id
                clashSelectedMember = nil
            } else {
                clashSelectedMember = member
            }
        } else if clashGroup == group {
            clashSelectedMember = nil
        }
    }
    var resolvedEngine: Engine { engine ?? .wireGuard }
    var autoUpdateEnabled: Bool { autoUpdate ?? true }

    var nextAutoUpdateDate: Date? {
        guard sourceURL != nil, autoUpdateEnabled, let lastUpdated = subscription?.lastUpdated else {
            return nil
        }
        let hours = updateIntervalOverrideHours ?? subscription?.updateIntervalHours ?? 24
        return lastUpdated.addingTimeInterval(TimeInterval(max(1, hours)) * 3600)
    }

    func isAutoUpdateDue(at date: Date) -> Bool {
        guard sourceURL != nil, autoUpdateEnabled else { return false }
        return nextAutoUpdateDate.map { $0 <= date } ?? true
    }
}

struct ProfileLibrary: Codable {
    var profiles: [Profile] = []
    var selectedProfileID: UUID?
    var mode: TrafficMode? = nil
    var overrides: ConfigurationOverrides? = nil

    var selectedProfile: Profile? { profiles.first { $0.id == selectedProfileID } }

    var trafficMode: TrafficMode { mode ?? .rule }

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
