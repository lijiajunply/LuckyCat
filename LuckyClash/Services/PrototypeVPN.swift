import Foundation
import NetworkExtension
import Observation

@Observable
final class PrototypeVPN {
    struct Traffic: Equatable {
        let received: UInt64
        let sent: UInt64
        let updatedAt: Date
    }

    enum Issue: Equatable {
        case permission
        case configuration
        case remote
        case storage
    }

    private(set) var status: NEVPNStatus = .invalid
    private(set) var busy = false
    private(set) var requestingConnection = false
    private(set) var imported: [ImportedNode] = []
    private(set) var importedRules: [RoutingRule] = []
    private(set) var importWarnings: [String] = []
    private(set) var stagedSourceURL: URL?
    private(set) var stagedEngine: Profile.Engine = .clash
    private(set) var stagedClashYAML: String?
    private(set) var stagedGroups: [ClashImportGroup] = []
    private(set) var stagedSubscription: Profile.Subscription?
    private var stagedSuggestedName: String?
    private(set) var updatingProfileID: UUID?
    private(set) var library = ProfileLibrary()
    let diagnostics = DiagnosticLog()
    /// Control channel to the Clash core owned by the running packet tunnel.
    let live: ClashLiveClient
    /// Connections, logs and rates for the network page.
    let network: NetworkStore
    private var libraryLoaded = false
    private(set) var importError: String?
    private(set) var traffic: Traffic?
    private(set) var extensionReady: Bool?
    private(set) var issue: Issue?
    private(set) var latencyTesting = false
    private(set) var switchingProfile = false
    private(set) var latencyProfileID: UUID?
    private(set) var latencyPending: Set<String> = []
    private(set) var latencyResults: [UUID: [String: Int]] = [:]
    private var latencyResultsByURL: [UUID: [String: [String: Int]]] = [:]
    private var latencyPendingURL: String?
    private(set) var liveGroupMembers: [String: [String]] = [:]
    private(set) var latencyTestedAt: [UUID: Date] = [:]
    var message: String?

    private let latencyTester = ClashLatencyTester.shared
    private var manager: NETunnelProviderManager?
    private var connectionRequest: UUID?
    private var statusChangedAt = UUID()
    private var stopRequest: UUID?
    // Keep the user's intent until the terminal status arrives, including
    // after the UI's pending-stop indicator has been cleared.
    private var intentionalStop = false
    private var diagnosticRequest: UUID?
    private var diagnosticUnavailableRecorded = false
    @ObservationIgnored private var trafficTask: Task<Void, Never>?

    init() {
        let live = ClashLiveClient()
        self.live = live
        self.network = NetworkStore(live: live)
    }

    var isActive: Bool {
        requestingConnection || stopRequest != nil || [.connecting, .connected, .reasserting, .disconnecting].contains(status)
    }

    var canStop: Bool {
        isActive && stopRequest == nil && status != .disconnecting
    }

    func importFile(_ url: URL) {
        guard !busy, !isActive else { return }
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            stage(try file.read(upToCount: ClashImport.maximumBytes + 1) ?? Data())
        } catch {
            importError = "无法读取配置文件。"
        }
    }

    func stage(_ data: Data, sourceURL: URL? = nil) {
        guard !busy, !isActive else { return }
        do {
            apply(try ClashImport.parse(data), sourceURL: sourceURL)
        } catch let clashError {
            do {
                let legacy = try ConfigurationImport.parse(data)
                apply(try ClashImport.fromLegacy(legacy), sourceURL: sourceURL)
            } catch {
                discardImport()
                importError = Self.describeImport(clashError)
            }
        }
    }

    func importURL(_ text: String) async -> Bool {
        guard !busy else {
            importError = "正在处理其他操作，请稍后重试。"
            return false
        }
        guard !isActive else {
            importError = "请先断开 VPN，再导入配置。"
            return false
        }
        guard let url = RemoteImport.url(from: text) else {
            importError = "请输入有效的 HTTPS 配置链接。"
            return false
        }
        discardImport()
        busy = true
        defer { busy = false }
        do {
            let response = try await RemoteImport.download(url)
            let metadata = SubscriptionHeader.parse(headers: response.headers)
            do {
                let document = try ClashImport.parse(response.data)
                apply(
                    document, sourceURL: url,
                    subscription: metadata.subscription,
                    suggestedName: metadata.suggestedName
                )
            } catch let clashError {
                do {
                    let legacy = try ConfigurationImport.parse(response.data)
                    apply(
                        try ClashImport.fromLegacy(legacy), sourceURL: url,
                        subscription: metadata.subscription,
                        suggestedName: metadata.suggestedName
                    )
                } catch {
                    importError = Self.describeImport(clashError)
                    return false
                }
            }
            return true
        } catch {
            importError = Self.describeImport(error)
            return false
        }
    }

    func discardImport() {
        imported = []
        importedRules = []
        importWarnings = []
        stagedSourceURL = nil
        stagedEngine = .clash
        stagedClashYAML = nil
        stagedGroups = []
        stagedSubscription = nil
        stagedSuggestedName = nil
        importError = nil
    }

    var hasStagedImport: Bool { stagedClashYAML != nil }

    var defaultImportName: String {
        if let suggested = stagedSuggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return String(suggested.prefix(80))
        }
        guard let url = stagedSourceURL else { return "" }
        let file = url.deletingPathExtension().lastPathComponent
        let candidate = file.isEmpty ? (url.host() ?? "") : file
        return String(candidate.prefix(80))
    }

    private func apply(
        _ document: ImportedConfiguration, sourceURL: URL?,
        subscription: Profile.Subscription? = nil, suggestedName: String? = nil
    ) {
        imported = document.nodes
        importedRules = document.rules
        importWarnings = document.warnings
        stagedSourceURL = sourceURL
        stagedEngine = document.engine
        stagedClashYAML = document.clashYAML
        stagedGroups = document.groups
        stagedSubscription = subscription
        stagedSuggestedName = suggestedName
        importError = nil
    }

    func saveImport(named name: String, selectedNode: String) -> Bool {
        guard libraryLoaded else {
            importError = PrototypeError.profileStorage.localizedDescription
            return false
        }
        guard !busy, !isActive else { return false }
        guard let yaml = stagedClashYAML else {
            importError = ClashImport.Failure.unreadable.localizedDescription
            return false
        }
        let profileID = UUID()
        let revision = UUID()
        do {
            try ClashTunnelStore.save(yaml, profileID: profileID, revision: revision)
            var nodes = imported.map { node in
                Profile.Node(
                    id: UUID(), name: node.name, endpoint: node.endpoint, type: node.type
                )
            }
            let synthesizedNode = nodes.isEmpty
            if synthesizedNode {
                nodes = [Profile.Node(
                    id: UUID(), name: "默认策略", endpoint: "由配置决定", type: "auto"
                )]
            }
            guard let selected = nodes.first(where: { $0.name == selectedNode }) ?? nodes.first else {
                throw PrototypeError.missingConfiguration
            }
            let profile = Profile(
                id: profileID, name: name, nodes: nodes, selectedNodeID: selected.id,
                sourceURL: stagedSourceURL, rules: nil, engine: .clash,
                clashRevision: revision,
                clashGroup: synthesizedNode
                    ? nil
                    : Self.selectableGroup(for: selected, in: stagedGroups),
                clashGroups: stagedGroups,
                subscription: stagedSubscription, autoUpdate: true
            )
            var updated = library
            updated.profiles.append(profile)
            updated.selectedProfileID = profileID
            try updated.save()
            library = updated
            let warnings = importWarnings
            discardImport()
            message = warnings.isEmpty ? nil : warnings.joined(separator: " ")
            record("配置已保存")
            return true
        } catch {
            ClashTunnelStore.remove(revision: revision)
            importError = Self.describeImport(error)
            return false
        }
    }

    private static func selectableGroup(
        for node: Profile.Node, in groups: [ClashImportGroup]
    ) -> String? {
        groups.first { $0.isSelectable && $0.members.contains(node.name) }?.name
            ?? groups.first(where: \.isSelectable)?.name
    }

    func setMode(_ mode: TrafficMode) {
        guard libraryLoaded, !busy, library.mode != mode else { return }
        var updated = library
        updated.mode = mode
        do {
            try updated.save()
            library = updated
            message = nil
            issue = nil
            record("切换分流模式")
        } catch {
            present(error)
            return
        }
        guard isActive else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if mode == .global {
                    guard let profile = self.library.selectedProfile,
                          let name = profile.clashSelectedMember ?? (profile.selectedNode?.type == "auto" ? nil : profile.selectedNode?.name) else {
                        throw ClashLiveFailure.rejected("全局模式需要选择一个代理节点。")
                    }
                    try await self.live.select(group: "GLOBAL", name: name)
                }
                try await self.live.setMode(mode)
                self.record("分流模式已应用到当前连接")
                do {
                    try await self.live.closeAllConnections()
                } catch {
                    self.message = "分流模式已切换，但关闭已有连接失败：\(error.localizedDescription)"
                }
            } catch {
                self.message = "分流模式已保存，但未能应用到当前连接：\(error.localizedDescription)"
            }
        }
    }

    func update(_ profile: Profile) async {
        guard libraryLoaded, !busy, !isActive,
              let sourceURL = profile.sourceURL,
              let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        if profile.resolvedEngine == .clash {
            await updateClash(profile, index: index, sourceURL: sourceURL)
            return
        }
        busy = true
        updatingProfileID = profile.id
        defer {
            busy = false
            updatingProfileID = nil
        }
        do {
            let migrated = try await migrateLegacy(
                profile, index: index, rewriteManager: true
            )
            await updateClash(migrated, index: index, sourceURL: sourceURL)
        } catch {
            message = Self.describeImport(error)
            issue = .configuration
        }
    }

    private func updateClash(_ profile: Profile, index: Int, sourceURL: URL) async {
        busy = true
        updatingProfileID = profile.id
        defer {
            busy = false
            updatingProfileID = nil
        }
        let revision = UUID()
        do {
            let response = try await RemoteImport.download(sourceURL)
            let metadata = SubscriptionHeader.parse(headers: response.headers)
            let document: ImportedConfiguration
            do {
                document = try ClashImport.parse(response.data)
            } catch {
                let legacy = try ConfigurationImport.parse(response.data)
                document = try ClashImport.fromLegacy(legacy)
            }
            guard let yaml = document.clashYAML else { throw ClashImport.Failure.unreadable }
            try ClashTunnelStore.save(yaml, profileID: profile.id, revision: revision)

            var nodes = document.nodes.map { node in
                Profile.Node(id: UUID(), name: node.name, endpoint: node.endpoint, type: node.type)
            }
            let synthesizedNode = nodes.isEmpty
            if synthesizedNode {
                nodes = [Profile.Node(
                    id: UUID(), name: profile.selectedNode?.name ?? "默认策略", endpoint: "由配置决定", type: "auto"
                )]
            }
            guard let selected = nodes.first(where: { $0.name == profile.selectedNode?.name }) ?? nodes.first else {
                throw PrototypeError.missingConfiguration
            }
            var subscription = profile.subscription ?? Profile.Subscription()
            Self.merge(metadata.subscription, into: &subscription)
            subscription.lastUpdated = Date()

            var updated = library
            updated.profiles[index] = Profile(
                id: profile.id, name: profile.name, nodes: nodes, selectedNodeID: selected.id,
                sourceURL: sourceURL, rules: nil, engine: .clash,
                clashRevision: revision,
                clashGroup: synthesizedNode
                    ? nil
                    : Self.selectableGroup(for: selected, in: document.groups),
                clashGroups: document.groups,
                subscription: subscription, autoUpdate: profile.autoUpdate,
                clashSelectedMember: profile.clashGroup.flatMap { group in
                    document.groups.first(where: { $0.name == group && $0.isSelectable })
                        .flatMap { $0.members.contains(profile.clashSelectedMember ?? "") ? profile.clashSelectedMember : nil }
                }
            )
            if updated.profiles[index].clashSelectedMember != nil {
                updated.profiles[index].clashGroup = profile.clashGroup
            }
            try updated.save()
            library = updated

            var canRemoveOldRevisions = true
            #if !targetEnvironment(simulator)
            do {
                if let manager = try await loadManager(),
                   let provider = manager.protocolConfiguration as? NETunnelProviderProtocol,
                   provider.providerConfiguration?[ClashTunnelStore.profileKey] as? String == profile.id.uuidString {
                    _ = try await saveClash(
                        profile: updated.profiles[index], node: selected, to: manager
                    )
                }
            } catch {
                canRemoveOldRevisions = false
            }
            #endif
            if canRemoveOldRevisions, let previous = profile.clashRevision {
                ClashTunnelStore.remove(revision: previous)
            }
            message = document.warnings.isEmpty ? nil : document.warnings.joined(separator: " ")
            issue = nil
            record("配置已更新")
        } catch {
            ClashTunnelStore.remove(revision: revision)
            message = Self.describeImport(error)
            issue = .configuration
        }
    }

    /// Moves a profile created by the retired WireGuard engine to a Clash
    /// configuration. The extension only links the Clash core, so no profile
    /// may stay on the WireGuard engine.
    private func migrateLegacy(
        _ profile: Profile, index: Int, rewriteManager: Bool
    ) async throws -> Profile {
        var nodes: [ImportedNode] = []
        for node in profile.nodes {
            guard let configuration = try? TunnelSnapshot.load(
                profileID: profile.id, revision: node.id
            ) else { continue }
            nodes.append(ImportedNode(
                name: node.name, type: "wireguard", endpoint: node.endpoint,
                configuration: configuration
            ))
        }
        let converted = try ClashImport.fromLegacy(ImportedConfiguration(
            engine: .wireGuard, nodes: nodes, rules: profile.rules ?? [], warnings: []
        ))
        guard let yaml = converted.clashYAML else { throw ClashImport.Failure.unreadable }

        let revision = UUID()
        try ClashTunnelStore.save(yaml, profileID: profile.id, revision: revision)
        let migratedNodes = converted.nodes.map { node in
            Profile.Node(id: UUID(), name: node.name, endpoint: node.endpoint, type: node.type)
        }
        guard let selected = migratedNodes.first(where: { $0.name == profile.selectedNode?.name })
            ?? migratedNodes.first else {
            throw PrototypeError.missingConfiguration
        }
        let group = converted.groups.first {
            $0.isSelectable && $0.members.contains(selected.name)
        }?.name
        let migrated = Profile(
            id: profile.id, name: profile.name, nodes: migratedNodes,
            selectedNodeID: selected.id, sourceURL: profile.sourceURL, rules: nil,
            engine: .clash, clashRevision: revision, clashGroup: group,
            clashGroups: converted.groups,
            subscription: profile.subscription, autoUpdate: profile.autoUpdate
        )
        var updated = library
        updated.profiles[index] = migrated
        try updated.save()
        library = updated
        for node in profile.nodes { TunnelSnapshot.remove(revision: node.id) }

        #if !targetEnvironment(simulator)
        if rewriteManager,
           let manager = try await loadManager(),
           let provider = manager.protocolConfiguration as? NETunnelProviderProtocol,
           provider.providerConfiguration?[TunnelSnapshot.profileKey] as? String == profile.id.uuidString {
            _ = try await saveClash(profile: migrated, node: selected, to: manager)
        }
        #endif
        record("旧配置已迁移")
        return migrated
    }

    private static func merge(
        _ incoming: Profile.Subscription, into target: inout Profile.Subscription
    ) {
        if let value = incoming.upload { target.upload = value }
        if let value = incoming.download { target.download = value }
        if let value = incoming.total { target.total = value }
        if let value = incoming.expire { target.expire = value }
        if let value = incoming.updateIntervalHours { target.updateIntervalHours = value }
        if let value = incoming.webPageURL { target.webPageURL = value }
    }

    func select(profileID: UUID) {
        guard libraryLoaded, !switchingProfile, (!busy || latencyTesting || isActive),
              let index = library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard library.selectedProfileID != profileID else { return }
        let reconnect = isActive
        applySelection(index: index, nodeID: nil)
        guard library.selectedProfileID == profileID, reconnect else { return }
        switchingProfile = true
        message = "正在切换配置并重新连接…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.switchingProfile = false }
            if self.latencyTesting { self.cancelLatencyTest() }
            // Let an in-flight connection request finish before stopping its tunnel.
            for _ in 0..<300 {
                if !self.busy && !self.latencyTesting { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !self.busy, !self.latencyTesting else {
                self.message = "切换配置超时，请断开后重试。"
                return
            }
            if self.canStop { self.disconnect() }
            for _ in 0..<300 {
                await self.updateStatus()
                if !self.isActive { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !self.isActive else {
                self.message = "断开当前连接超时，请手动断开后重试。"
                return
            }
            await self.connect()
        }
    }

    func select(profileID: UUID, nodeID: UUID, group: String? = nil) {
        guard libraryLoaded, (!busy || latencyTesting), !switchingProfile,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }),
              let node = library.profiles[index].nodes.first(where: { $0.id == nodeID }) else { return }
        guard isActive else {
            applySelection(index: index, nodeID: nodeID, group: group)
            return
        }
        guard activeProfileID == profileID else {
            message = "请先断开 VPN，再切换其他配置的节点。"
            return
        }
        switchNodeOnLiveCore(profileID: profileID, node: node, group: group)
    }

    func selectMember(profileID: UUID, group: ClashImportGroup, member: String) {
        guard libraryLoaded, canSwitchNodes(for: profileID), group.isSelectable,
              members(for: group).contains(member),
              let index = library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        if let node = library.profiles[index].nodes.first(where: { $0.name == member }) {
            select(profileID: profileID, nodeID: node.id, group: group.name)
            return
        }
        if !isActive {
            applyMemberSelection(index: index, group: group.name, member: member)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.live.select(group: group.name, name: member)
                if self.library.trafficMode == .global {
                    try await self.live.select(group: "GLOBAL", name: member)
                }
                guard self.activeProfileID == profileID,
                      let index = self.library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
                self.applyMemberSelection(index: index, group: group.name, member: member)
                if UserDefaults.standard.object(forKey: "closeConnectionsOnNodeSwitch") as? Bool ?? true {
                    do { try await self.live.closeAllConnections() }
                    catch { self.message = "策略已切换，但关闭已有连接失败：\(error.localizedDescription)" }
                }
            } catch {
                self.message = "切换策略失败：\(error.localizedDescription)"
            }
        }
    }

    private func applyMemberSelection(index: Int, group: String, member: String) {
        var updated = library
        updated.selectedProfileID = updated.profiles[index].id
        updated.profiles[index].clashGroup = group
        updated.profiles[index].clashSelectedMember = member
        do {
            try updated.save()
            library = updated
            message = nil
            issue = nil
            record("切换策略")
        } catch { present(error) }
    }

    /// The active profile's node can be switched on the running core; any
    /// other profile still needs a reconnect.
    func canSwitchNodes(for profileID: UUID) -> Bool {
        guard (!busy || latencyTesting), !switchingProfile else { return false }
        guard isActive else { return true }
        return activeProfileID == profileID
    }

    private var activeProfileID: UUID? {
        guard let provider = manager?.protocolConfiguration as? NETunnelProviderProtocol,
              let raw = provider.providerConfiguration?[ClashTunnelStore.profileKey] as? String else {
            return library.selectedProfileID
        }
        return UUID(uuidString: raw) ?? library.selectedProfileID
    }

    private func switchNodeOnLiveCore(profileID: UUID, node: Profile.Node, group: String?) {
        guard let profile = library.profiles.first(where: { $0.id == profileID }) else { return }
        let targetGroup = group ?? Self.group(containing: node, in: profile.clashGroups ?? [])
        let globalMode = library.trafficMode == .global
        guard globalMode || !(targetGroup ?? "").isEmpty else {
            // No selectable group: keep the choice for the next connection.
            if let index = library.profiles.firstIndex(where: { $0.id == profileID }) {
                applySelection(index: index, nodeID: node.id, group: nil)
            }
            message = "当前配置没有可手动切换的策略组，新的节点将在下次连接时生效。"
            return
        }
        message = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                if let targetGroup, !targetGroup.isEmpty {
                    try await self.live.select(group: targetGroup, name: node.name)
                }
                if globalMode {
                    try await self.live.select(group: "GLOBAL", name: node.name)
                }
                if UserDefaults.standard.object(forKey: "closeConnectionsOnNodeSwitch") as? Bool ?? true {
                    do {
                        try await self.live.closeAllConnections()
                    } catch {
                        self.message = "节点已切换，但关闭已有连接失败：\(error.localizedDescription)"
                    }
                }
                guard !self.switchingProfile, self.library.selectedProfileID == profileID else { return }
                guard let index = self.library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
                self.applySelection(index: index, nodeID: node.id, group: targetGroup)
                self.issue = nil
                self.record("切换节点（连接中）")
            } catch {
                self.message = "切换节点失败：\(error.localizedDescription)"
            }
        }
    }

    private static func group(containing node: Profile.Node, in groups: [ClashImportGroup]) -> String? {
        groups.first { $0.isSelectable && $0.members.contains(node.name) }?.name
    }

    private func applySelection(index: Int, nodeID: UUID?, group: String? = nil) {
        var updated = library
        let alreadySelected = updated.selectedProfileID == updated.profiles[index].id
            && (nodeID == nil || updated.profiles[index].selectedNodeID == nodeID)
            && (nodeID == nil || updated.profiles[index].clashSelectedMember == nil)
            && (group == nil || updated.profiles[index].clashGroup == group)
        guard !alreadySelected else { return }
        updated.selectedProfileID = updated.profiles[index].id
        if let nodeID {
            updated.profiles[index].selectedNodeID = nodeID
            updated.profiles[index].clashSelectedMember = nil
            if updated.profiles[index].resolvedEngine == .clash,
               let node = updated.profiles[index].nodes.first(where: { $0.id == nodeID }) {
                let groups = updated.profiles[index].clashGroups ?? []
                if let group, groups.contains(where: { $0.name == group && $0.members.contains(node.name) }) {
                    updated.profiles[index].clashGroup = group
                } else {
                    updated.profiles[index].clashGroup = Self.selectableGroup(for: node, in: groups)
                }
            }
        }
        do {
            try updated.save()
            library = updated
            message = nil
            issue = nil
            record("切换配置")
        } catch {
            present(error)
        }
    }

    func remove(_ profile: Profile) async {
        guard libraryLoaded, !busy, !isActive, library.profiles.contains(where: { $0.id == profile.id }) else { return }
        busy = true
        defer { busy = false }
        do {
            #if !targetEnvironment(simulator)
            adopt(try await loadManager())
            guard !isActive else { throw PrototypeError.activeConfiguration }
            if let manager,
               let values = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
               values[TunnelSnapshot.profileKey] as? String == profile.id.uuidString {
                try await manager.removeFromPreferences()
                adopt(nil)
            }
            #endif
            var updated = library
            updated.profiles.removeAll { $0.id == profile.id }
            if updated.selectedProfileID == profile.id {
                updated.selectedProfileID = updated.profiles.first?.id
            }
            try updated.save()
            library = updated
            if profile.resolvedEngine == .clash {
                if let revision = profile.clashRevision {
                    ClashTunnelStore.remove(revision: revision)
                }
                for node in profile.nodes { ClashTunnelStore.remove(revision: node.id) }
            } else {
                for node in profile.nodes { TunnelSnapshot.remove(revision: node.id) }
            }
            message = nil
            issue = nil
            record("配置已删除")
        } catch {
            present(error)
        }
    }

    func setAutoUpdate(_ enabled: Bool, for profileID: UUID) {
        guard libraryLoaded, !busy, !isActive,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var updated = library
        updated.profiles[index].autoUpdate = enabled
        do {
            try updated.save()
            library = updated
            record("切换自动更新")
        } catch {
            present(error)
        }
    }

    func rename(profileID: UUID, to newName: String) {
        let name = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard libraryLoaded, !busy, !isActive, !name.isEmpty,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }),
              library.profiles[index].name != name else { return }
        var updated = library
        updated.profiles[index].name = name
        do {
            try updated.save()
            library = updated
            message = nil
            issue = nil
            record("配置已重命名")
        } catch {
            present(error)
        }
    }

    func latencyState(for nodeName: String, profileID: UUID, testURL: String? = nil) -> LatencyState {
        let url = effectiveTestURL(testURL, profileID: profileID)
        if latencyProfileID == profileID, latencyTesting, latencyPendingURL == url, latencyPending.contains(nodeName) {
            return .testing
        }
        let value = latencyResultsByURL[profileID]?[url]?[nodeName]
            ?? (latencyResultsByURL[profileID] == nil ? latencyResults[profileID]?[nodeName] : nil)
        guard let value else { return .untested }
        return value >= 0 ? .value(value) : .failed
    }

    func latencyValue(for nodeName: String, profileID: UUID) -> Int? {
        let url = effectiveTestURL(nil, profileID: profileID)
        let value = latencyResultsByURL[profileID]?[url]?[nodeName]
            ?? (latencyResultsByURL[profileID] == nil ? latencyResults[profileID]?[nodeName] : nil)
        guard let value, value >= 0 else { return nil }
        return value
    }

    func cancelLatencyTest() {
        guard latencyTesting else { return }
        latencyTester.cancel()
        live.cancelURLTests()
        message = "正在停止延迟测试…"
    }

    func refreshLiveGroups() async {
        guard status == .connected, let profile = library.selectedProfile,
              activeProfileID == profile.id else {
            liveGroupMembers = [:]
            return
        }
        do {
            let groups = try await live.groupMembers((profile.clashGroups ?? []).map(\.name))
            guard status == .connected, library.selectedProfileID == profile.id else { return }
            liveGroupMembers = groups
        } catch {
            liveGroupMembers = [:]
        }
    }

    func members(for group: ClashImportGroup) -> [String] {
        liveGroupMembers[group.name] ?? group.members
    }

    /// Runs a URL test for every node in the selected profile. While the
    /// tunnel is running the test goes through its live core, so delays are
    /// measured on the path the tunnel already uses; otherwise a short-lived
    /// core owned by this process is used.
    func testLatency(nodeNames: [String]? = nil, testURL: String? = nil) async {
        guard !busy, !latencyTesting else { return }
        guard libraryLoaded, let profile = library.selectedProfile else {
            message = "请先在连接页选择一个配置。"
            return
        }
        let groups = (profile.clashGroups ?? []).map { group in
            ClashImportGroup(name: group.name, type: group.type, members: members(for: group), testURL: group.testURL)
        }
        let dynamicNames = isActive ? liveGroupMembers.values.flatMap { $0 } : []
        let groupNames = Set(groups.map(\.name))
        let availableNames = Array(NSOrderedSet(array: Self.uniqueNodeNames(profile) + dynamicNames))
            .compactMap { $0 as? String }.filter { !groupNames.contains($0) && $0 != "DIRECT" && $0 != "REJECT" }
        let requested = nodeNames.map { Set(Self.expandGroupMembers($0, groups: groups)) }
        let names = availableNames.filter { requested == nil || requested!.contains($0) }
        guard !names.isEmpty else {
            message = "该范围没有可测速的本地节点。"
            return
        }
        if isActive {
            await testLatencyLive(profile, names: names, testURL: testURL)
            return
        }
        guard let revision = profile.clashRevision,
              let yaml = try? ClashTunnelStore.load(profileID: profile.id, revision: revision) else {
            message = "找不到该配置的本地文件，请更新或重新导入。"
            issue = .configuration
            return
        }
        busy = true
        latencyTesting = true
        latencyProfileID = profile.id
        latencyPending = Set(names)
        let testURL = effectiveTestURL(testURL, profileID: profile.id)
        latencyPendingURL = testURL
        if latencyResultsByURL[profile.id]?[testURL] == nil {
            latencyResultsByURL[profile.id, default: [:]][testURL] = [:]
        }
        for name in names { latencyResultsByURL[profile.id]?[testURL]?.removeValue(forKey: name) }
        for name in names { latencyResults[profile.id]?.removeValue(forKey: name) }
        message = nil
        issue = nil
        record("开始延迟测试")
        defer {
            busy = false
            latencyTesting = false
            latencyProfileID = nil
            latencyPending = []
            latencyPendingURL = nil
        }

        do {
            let results = try await latencyTester.measure(
                configuration: yaml, nodes: names, testURL: testURL
            ) { [weak self] name, delay in
                Task { @MainActor [weak self] in
                    self?.applyLatency(name, delay: delay, profileID: profile.id, testURL: testURL)
                }
            }
            for (name, delay) in results {
                applyLatency(name, delay: delay, profileID: profile.id, testURL: testURL)
            }
            latencyTestedAt[profile.id] = Date()
            if !names.allSatisfy({ latencyResults[profile.id]?[$0] != nil }) {
                message = "部分节点没有返回延迟。"
            }
            record("延迟测试完成")
        } catch {
            message = error.localizedDescription
            issue = Self.issue(for: error)
            record("延迟测试失败")
        }
    }

    private func testLatencyLive(_ profile: Profile, names: [String], testURL: String?) async {

        latencyTesting = true
        latencyProfileID = profile.id
        latencyPending = Set(names)
        let testURL = effectiveTestURL(testURL, profileID: profile.id)
        latencyPendingURL = testURL
        if latencyResultsByURL[profile.id]?[testURL] == nil {
            latencyResultsByURL[profile.id, default: [:]][testURL] = [:]
        }
        for name in names { latencyResultsByURL[profile.id]?[testURL]?.removeValue(forKey: name) }
        for name in names { latencyResults[profile.id]?.removeValue(forKey: name) }
        message = nil
        issue = nil
        record("开始延迟测试")
        defer {
            latencyTesting = false
            latencyProfileID = nil
            latencyPending = []
            latencyPendingURL = nil
        }

        do {
            let results = try await live.urlTest(
                names: names, testURL: testURL
            ) { [weak self] name, delay in
                Task { @MainActor [weak self] in
                    self?.applyLatency(name, delay: delay, profileID: profile.id, testURL: testURL)
                }
            }
            for (name, delay) in results {
                applyLatency(name, delay: delay, profileID: profile.id, testURL: testURL)
            }
            latencyTestedAt[profile.id] = Date()
            if !names.allSatisfy({ latencyResults[profile.id]?[$0] != nil }) {
                message = "部分节点没有返回延迟。"
            }
            record("延迟测试完成")
        } catch {
            message = error.localizedDescription
            record("延迟测试失败")
        }
    }

    private static func testURL(for profile: Profile) -> String {
        let groupURL = profile.clashGroups?.first(where: { $0.name == profile.clashGroup })?.testURL
        return normalizedTestURL(groupURL)
    }

    static func normalizedTestURL(_ groupURL: String?) -> String {
        let configured = UserDefaults.standard.string(forKey: "latencyTestURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return groupURL.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? configured.flatMap { $0.isEmpty ? nil : $0 }
            ?? ClashLatencyTester.defaultTestURL
    }

    private func effectiveTestURL(_ url: String?, profileID: UUID) -> String {
        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty { return url }
        guard let profile = library.profiles.first(where: { $0.id == profileID }) else {
            return ClashLatencyTester.defaultTestURL
        }
        return Self.testURL(for: profile)
    }

    static func expandGroupMembers(_ names: [String], groups: [ClashImportGroup]) -> [String] {
        let groupsByName = Dictionary(groups.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var visited = Set<String>()
        var result: [String] = []
        func visit(_ name: String) {
            guard visited.insert(name).inserted else { return }
            if let group = groupsByName[name] {
                group.members.forEach(visit)
            } else {
                result.append(name)
            }
        }
        names.forEach(visit)
        return result
    }

    private func applyLatency(_ name: String, delay: Int, profileID: UUID, testURL: String) {
        latencyPending.remove(name)
        latencyResults[profileID, default: [:]][name] = delay
        latencyResultsByURL[profileID, default: [:]][testURL, default: [:]][name] = delay
    }

    private func hasAllLatencyResults(_ profile: Profile, profileID: UUID) -> Bool {
        let names = Self.uniqueNodeNames(profile)
        guard !names.isEmpty, let results = latencyResults[profileID] else { return false }
        return names.allSatisfy { results[$0] != nil }
    }

    private static func uniqueNodeNames(_ profile: Profile) -> [String] {
        let isSynthesized = profile.nodes.count == 1 && profile.nodes[0].type == "auto"
        guard !isSynthesized else { return [] }
        var seen = Set<String>()
        return profile.nodes.compactMap { node in
            let name = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return seen.insert(name).inserted ? name : nil
        }
    }

    func updateAll() async {
        guard !busy, !isActive else { return }
        for profile in library.profiles where profile.sourceURL != nil {
            await update(profile)
        }
    }

    func updateDueProfiles() async {
        guard !busy, !isActive else { return }
        let now = Date()
        let due = library.profiles.filter { profile in
            guard profile.sourceURL != nil, profile.autoUpdateEnabled,
                  let last = profile.subscription?.lastUpdated else { return false }
            let hours = profile.subscription?.updateIntervalHours ?? 24
            return now.timeIntervalSince(last) >= TimeInterval(hours * 3600)
        }
        for profile in due {
            await update(profile)
        }
    }

    func refresh() async {
        if !libraryLoaded {
            do {
                library = try ProfileLibrary.load()
                libraryLoaded = true
            } catch {
                message = "无法读取本地配置列表。"
            }
        }
        #if !targetEnvironment(simulator)
        guard !busy, !requestingConnection else { return }
        busy = true
        defer { busy = false }
        do {
            adopt(try await loadManager())
            if !isActive,
               let selected = library.selectedProfile,
               selected.resolvedEngine == .wireGuard,
               let index = library.profiles.firstIndex(where: { $0.id == selected.id }) {
                _ = try await migrateLegacy(selected, index: index, rewriteManager: true)
            }
            if status == .connected { queryExtensionStatus() }
        } catch {
            present(error)
        }
        #endif
    }

    func connect() async {
        #if targetEnvironment(simulator)
        record("模拟器连接请求")
        message = PrototypeError.simulator.localizedDescription
        #else
        guard !busy, !isActive else { return }
        busy = true
        defer { busy = false }
        intentionalStop = false
        message = nil
        issue = nil
        traffic = nil
        extensionReady = nil
        diagnosticUnavailableRecorded = false

        do {
            let existing = try await loadManager()
            adopt(existing)
            guard !isActive else { return }
            let selected: NETunnelProviderManager
            if let selectedProfile = library.selectedProfile {
                guard let index = library.profiles.firstIndex(where: { $0.id == selectedProfile.id }) else {
                    throw PrototypeError.missingConfiguration
                }
                var profile = selectedProfile
                if profile.resolvedEngine == .wireGuard {
                    message = "正在迁移旧版 WireGuard 配置…"
                    profile = try await migrateLegacy(
                        profile, index: index, rewriteManager: false
                    )
                    message = nil
                }
                guard let node = profile.selectedNode else {
                    throw PrototypeError.missingConfiguration
                }
                let revision = profile.clashRevision ?? node.id
                let yaml = try ClashTunnelStore.load(profileID: profile.id, revision: revision)
                if ClashGeodata.isRequired(yaml) {
                    message = "正在准备 GeoIP 数据…"
                    try await ClashGeodata.ensure(yaml: yaml)
                    message = nil
                }
                selected = try await saveClash(
                    profile: profile, node: node, to: existing ?? NETunnelProviderManager()
                )
            } else {
                throw PrototypeError.missingConfiguration
            }

            adopt(selected)
            guard let session = selected.connection as? NETunnelProviderSession else {
                throw PrototypeError.missingConfiguration
            }

            let request = UUID()
            connectionRequest = request
            requestingConnection = true
            network.start()
            do {
                try session.startTunnel(options: nil)
                record("发起连接")
            } catch {
                clearConnectionRequest()
                throw error
            }
            await updateStatus()
            if connectionRequest == request {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, self.connectionRequest == request else { return }
                    self.clearConnectionRequest()
                    await self.updateStatus()
                    if self.status == .disconnected {
                        self.message = "iOS 未启动连接，请检查系统 VPN 设置。"
                        self.issue = .permission
                        self.network.stop()
                    }
                }
            }
        } catch {
            present(error)
            if !isActive {
                network.stop()
            }
        }
        #endif
    }

    func disconnect() {
        guard !busy, canStop else { return }
        guard let connection = manager?.connection else { return }
        clearConnectionRequest()
        message = nil
        issue = nil
        let request = UUID()
        stopRequest = request
        intentionalStop = true
        connection.stopVPNTunnel()
        record("请求断开")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.stopRequest == request else { return }
            self.stopRequest = nil
            await self.updateStatus()
            if self.manager?.connection === connection,
               ![.disconnecting, .disconnected].contains(connection.status) {
                self.intentionalStop = false
            }
        }
    }

    func updateStatus() async {
        guard let connection = manager?.connection else { return }
        let previous = status
        let current = connection.status
        let wasIntentionalStop = intentionalStop
        if current == .disconnected || current == .invalid ||
            (previous == .disconnecting && current == .connected) {
            intentionalStop = false
        }
        if current != previous {
            statusChangedAt = UUID()
            status = current
        }
        if [.disconnected, .disconnecting, .invalid].contains(current) {
            stopRequest = nil
        }
        if current != previous {
            record("系统 VPN 状态 \(current.rawValue)")
            diagnosticRequest = nil
            if current == .connected {
                message = nil
                issue = nil
                diagnosticUnavailableRecorded = false
                queryExtensionStatus()
            }
        }
        syncTrafficPolling()
        syncNetworkMonitoring()
        let update = statusChangedAt
        if current == .connecting || current == .connected || current == .reasserting {
            clearConnectionRequest()
        }
        guard current == .disconnected, previous != .disconnected else { return }
        guard !wasIntentionalStop else { return }
        let error: NSError?
        do {
            try await connection.fetchLastDisconnectError()
            error = nil
        } catch let disconnectError {
            error = disconnectError as NSError
        }
        guard statusChangedAt == update, manager?.connection === connection, let error else { return }
        present(error)
        record("断开错误码 \(error.code)")
    }

    private func queryExtensionStatus() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let id = UUID()
        diagnosticRequest = id
        do {
            let request = TunnelStatusMessage.Request(version: TunnelStatusMessage.version, id: id)
            let data = try JSONEncoder().encode(request)
            try session.sendProviderMessage(data) { [weak self] response in
                Task { @MainActor [weak self] in
                    self?.finishStatusQuery(id: id, response: response)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.finishStatusQuery(id: id, response: nil)
            }
        } catch {
            finishStatusQuery(id: id, response: nil)
        }
    }

    private func finishStatusQuery(id: UUID, response: Data?) {
        guard diagnosticRequest == id else { return }
        diagnosticRequest = nil
        guard status == .connected else { return }
        guard let response,
              let reply = try? JSONDecoder().decode(TunnelStatusMessage.Reply.self, from: response),
              reply.version == TunnelStatusMessage.version, reply.id == id else {
            let wasAvailable = extensionReady != nil
            extensionReady = nil
            if wasAvailable || !diagnosticUnavailableRecorded {
                record("扩展诊断暂不可用")
                diagnosticUnavailableRecorded = true
            }
            return
        }
        let previous = extensionReady
        extensionReady = reply.ready
        if let bytesIn = reply.bytesIn, let bytesOut = reply.bytesOut {
            traffic = Traffic(received: bytesIn, sent: bytesOut, updatedAt: .now)
        }
        if previous != reply.ready {
            record(reply.ready ? "扩展已就绪" : "扩展未就绪")
        }
    }

    private func syncTrafficPolling() {
        guard status == .connected else {
            trafficTask?.cancel()
            trafficTask = nil
            traffic = nil
            extensionReady = nil
            return
        }
        guard trafficTask == nil else { return }
        trafficTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { break }
                self.queryExtensionStatus()
            }
        }
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        let providerID = try Self.providerIdentifier()
        let matches = try await NETunnelProviderManager.loadAllFromPreferences().filter { manager in
            guard let provider = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
            return provider.providerBundleIdentifier == providerID
                && provider.providerConfiguration?[PrototypeStore.configurationIdentifierKey] as? String
                    == PrototypeStore.configurationIdentifier
        }
        guard matches.count <= 1 else { throw PrototypeError.duplicateConfiguration }
        return matches.first
    }

    private func saveClash(
        profile: Profile,
        node: Profile.Node,
        to manager: NETunnelProviderManager
    ) async throws -> NETunnelProviderManager {
        let provider = NETunnelProviderProtocol()
        provider.providerBundleIdentifier = try Self.providerIdentifier()
        provider.serverAddress = "LuckyClash"
        provider.providerConfiguration = [
            PrototypeStore.configurationIdentifierKey: PrototypeStore.configurationIdentifier,
            ClashTunnelStore.engineKey: ClashTunnelStore.engineClash,
            ClashTunnelStore.profileKey: profile.id.uuidString,
            ClashTunnelStore.revisionKey: (profile.clashRevision ?? node.id).uuidString,
            ClashTunnelStore.selectedGroupKey: profile.clashGroup ?? "",
            ClashTunnelStore.selectedNodeKey: profile.clashSelectedMember ?? (node.type == "auto" ? "" : node.name),
            ClashTunnelStore.modeKey: library.trafficMode.rawValue
        ]
        manager.protocolConfiguration = provider
        manager.localizedDescription = "LuckyClash"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }

    private func record(_ event: String) {
        diagnostics.append(event)
    }

    private func present(_ error: Error) {
        message = Self.describe(error)
        issue = Self.issue(for: error)
    }

    static func issue(for error: Error) -> Issue? {
        if error is ClashImport.Failure { return .configuration }
        if error is ClashLatencyFailure { return .remote }
        if error is ClashGeodata.Failure { return .remote }
        let nsError = error as NSError
        if nsError.domain == PrototypeError.errorDomain,
           let prototype = PrototypeError(rawValue: nsError.code) {
            switch prototype {
            case .keychainUnavailable, .sharedContainerUnavailable:
                return .permission
            case .missingConfiguration, .engineStartup, .networkSettings,
                 .duplicateConfiguration, .activeConfiguration, .invalidRulePlan:
                return .configuration
            case .handshakeTimeout:
                return .remote
            case .profileStorage:
                return .storage
            case .startCancelled, .simulator:
                return nil
            }
        }
        if nsError.domain == NSCocoaErrorDomain { return .storage }
        if nsError.domain == NEVPNErrorDomain,
           let code = NEVPNError.Code(rawValue: nsError.code) {
            switch code {
            case .configurationReadWriteFailed: return .permission
            case .configurationInvalid, .configurationDisabled, .configurationStale, .configurationUnknown:
                return .configuration
            case .connectionFailed: return .remote
            default: return nil
            }
        }
        return .remote
    }

    private func adopt(_ manager: NETunnelProviderManager?) {
        self.manager = manager
        status = manager?.connection.status ?? .invalid
        syncTrafficPolling()
        syncNetworkMonitoring()
    }

    /// Keeps the network page attached to the tunnel's core while it runs.
    private func syncNetworkMonitoring() {
        switch status {
        case .connecting, .connected, .reasserting:
            network.start()
        case .disconnected, .invalid:
            network.stop()
        default:
            break
        }
    }

    private func clearConnectionRequest() {
        requestingConnection = false
        connectionRequest = nil
    }

    private static func providerIdentifier() throws -> String {
        guard let app = Bundle.main.bundleIdentifier else { throw PrototypeError.missingConfiguration }
        return app + ".PacketTunnel"
    }

    private static func describeImport(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "无法读取配置。"
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == PrototypeError.errorDomain,
           let prototype = PrototypeError(rawValue: nsError.code) {
            return prototype.localizedDescription
        }
        if nsError.domain == NSCocoaErrorDomain {
            return PrototypeError.profileStorage.localizedDescription
        }
        if nsError.domain == NEVPNErrorDomain && nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
            return "无法读写系统 VPN 配置，请核对 VPN 授权和签名。"
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        return "VPN 操作失败（\(nsError.domain) \(nsError.code)）。"
    }
}

#if DEBUG
extension PrototypeVPN {
    /// Builds a fully in-memory instance for SwiftUI previews. It never loads
    /// the on-disk library and never talks to NetworkExtension.
    static func preview(
        library: ProfileLibrary = PreviewSamples.library(),
        status: NEVPNStatus = .disconnected,
        message: String? = nil,
        issue: Issue? = nil,
        traffic: Traffic? = nil,
        extensionReady: Bool? = nil,
        latencyResults: [UUID: [String: Int]] = [:],
        latencyTesting: Bool = false,
        latencyProfileID: UUID? = nil,
        busy: Bool = false
    ) -> PrototypeVPN {
        let vpn = PrototypeVPN()
        vpn.library = library
        vpn.libraryLoaded = true
        vpn.status = status
        vpn.message = message
        vpn.issue = issue
        vpn.traffic = traffic
        vpn.extensionReady = extensionReady
        vpn.latencyResults = latencyResults
        vpn.latencyTesting = latencyTesting
        vpn.latencyProfileID = latencyProfileID
        vpn.busy = busy
        return vpn
    }

    /// Seeds the network page with sample connections and logs.
    static func previewNetwork(status: NetworkStore.Status = .streaming) -> PrototypeVPN {
        let vpn = PrototypeVPN()
        vpn.library = PreviewSamples.library()
        vpn.libraryLoaded = true
        vpn.status = .connected
        vpn.network.seed(status: status)
        return vpn
    }

    /// Seeds a staged import so the import preview sheet can be rendered.
    static func previewStaged(
        sourceURL: URL? = PreviewSamples.subscriptionURL,
        subscription: Profile.Subscription? = PreviewSamples.subscription(),
        suggestedName: String? = "示例订阅"
    ) -> PrototypeVPN {
        let vpn = PrototypeVPN()
        vpn.libraryLoaded = true
        vpn.imported = PreviewSamples.importedNodes
        vpn.importedRules = PreviewSamples.importedRules
        vpn.importWarnings = PreviewSamples.importWarnings
        vpn.stagedSourceURL = sourceURL
        vpn.stagedEngine = .clash
        vpn.stagedClashYAML = "proxies: []\n"
        vpn.stagedGroups = PreviewSamples.groups
        vpn.stagedSubscription = subscription
        vpn.stagedSuggestedName = suggestedName
        return vpn
    }
}
#endif
