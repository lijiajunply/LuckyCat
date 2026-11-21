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
    private var libraryLoaded = false
    private(set) var importError: String?
    private(set) var traffic: Traffic?
    private(set) var extensionReady: Bool?
    private(set) var issue: Issue?
    private(set) var latencyTesting = false
    private(set) var latencyProfileID: UUID?
    private(set) var latencyPending: Set<String> = []
    private(set) var latencyResults: [UUID: [String: Int]] = [:]
    private(set) var latencyTestedAt: [UUID: Date] = [:]
    var message: String?

    private let latencyTester = ClashLatencyTester.shared
    private var manager: NETunnelProviderManager?
    private var connectionRequest: UUID?
    private var statusChangedAt = UUID()
    private var stopRequest: UUID?
    private var diagnosticRequest: UUID?
    private var diagnosticUnavailableRecorded = false
    @ObservationIgnored private var trafficTask: Task<Void, Never>?

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
        guard libraryLoaded, !busy, !isActive, library.mode != mode else { return }
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
                subscription: subscription, autoUpdate: profile.autoUpdate
            )
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
        guard libraryLoaded, !busy, !isActive,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        applySelection(index: index, nodeID: nil)
    }

    func select(profileID: UUID, nodeID: UUID, group: String? = nil) {
        guard libraryLoaded, !busy, !isActive,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }),
              library.profiles[index].nodes.contains(where: { $0.id == nodeID }) else { return }
        applySelection(index: index, nodeID: nodeID, group: group)
    }

    private func applySelection(index: Int, nodeID: UUID?, group: String? = nil) {
        var updated = library
        let alreadySelected = updated.selectedProfileID == updated.profiles[index].id
            && (nodeID == nil || updated.profiles[index].selectedNodeID == nodeID)
            && (group == nil || updated.profiles[index].clashGroup == group)
        guard !alreadySelected else { return }
        updated.selectedProfileID = updated.profiles[index].id
        if let nodeID {
            updated.profiles[index].selectedNodeID = nodeID
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

    func latencyState(for nodeName: String, profileID: UUID) -> LatencyState {
        if latencyProfileID == profileID, latencyTesting, latencyPending.contains(nodeName) {
            return .testing
        }
        guard let value = latencyResults[profileID]?[nodeName] else { return .untested }
        return value >= 0 ? .value(value) : .failed
    }

    func latencyValue(for nodeName: String, profileID: UUID) -> Int? {
        guard let value = latencyResults[profileID]?[nodeName], value >= 0 else { return nil }
        return value
    }

    func cancelLatencyTest() {
        guard latencyTesting else { return }
        latencyTester.cancel()
        message = "正在停止延迟测试…"
    }

    /// Runs a URL test for every node in the selected profile through a
    /// short-lived Clash core owned by this process. The core is configured
    /// without listeners or rules, so it is only ever used to measure delays.
    func testLatency() async {
        guard !busy, !latencyTesting else { return }
        guard !isActive else {
            message = "请先断开 VPN，再进行延迟测试。"
            return
        }
        guard libraryLoaded, let profile = library.selectedProfile else {
            message = "请先在连接页选择一个配置。"
            return
        }
        guard let revision = profile.clashRevision,
              let yaml = try? ClashTunnelStore.load(profileID: profile.id, revision: revision) else {
            message = "找不到该配置的本地文件，请更新或重新导入。"
            issue = .configuration
            return
        }
        let names = Self.uniqueNodeNames(profile)
        guard !names.isEmpty else {
            message = "该配置的节点由 proxy-providers 提供，无法直接测试延迟。"
            return
        }

        busy = true
        latencyTesting = true
        latencyProfileID = profile.id
        latencyPending = Set(names)
        latencyResults[profile.id] = [:]
        latencyTestedAt[profile.id] = nil
        message = nil
        issue = nil
        record("开始延迟测试")
        defer {
            busy = false
            latencyTesting = false
            latencyProfileID = nil
            latencyPending = []
        }

        let testURL = profile.clashGroups?
            .compactMap(\.testURL)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? ClashLatencyTester.defaultTestURL

        do {
            let results = try await latencyTester.measure(
                configuration: yaml, nodes: names, testURL: testURL
            ) { [weak self] name, delay in
                Task { @MainActor [weak self] in
                    self?.applyLatency(name, delay: delay, profileID: profile.id)
                }
            }
            for (name, delay) in results {
                applyLatency(name, delay: delay, profileID: profile.id)
            }
            latencyTestedAt[profile.id] = Date()
            if let current = library.profiles.first(where: { $0.id == profile.id }),
               !hasAllLatencyResults(current, profileID: profile.id) {
                message = "部分节点没有返回延迟。"
            }
            record("延迟测试完成")
        } catch {
            message = error.localizedDescription
            issue = Self.issue(for: error)
            record("延迟测试失败")
        }
    }

    private func applyLatency(_ name: String, delay: Int, profileID: UUID) {
        latencyPending.remove(name)
        latencyResults[profileID, default: [:]][name] = delay
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
                    }
                }
            }
        } catch {
            present(error)
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
        connection.stopVPNTunnel()
        record("请求断开")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.stopRequest == request else { return }
            self.stopRequest = nil
            await self.updateStatus()
        }
    }

    func updateStatus() async {
        guard let connection = manager?.connection else { return }
        let previous = status
        let current = connection.status
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
        let update = statusChangedAt
        if current == .connecting || current == .connected || current == .reasserting {
            clearConnectionRequest()
        }
        guard current == .disconnected, previous != .disconnected else { return }
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
        provider.serverAddress = "LuckyCat"
        provider.providerConfiguration = [
            PrototypeStore.configurationIdentifierKey: PrototypeStore.configurationIdentifier,
            ClashTunnelStore.engineKey: ClashTunnelStore.engineClash,
            ClashTunnelStore.profileKey: profile.id.uuidString,
            ClashTunnelStore.revisionKey: (profile.clashRevision ?? node.id).uuidString,
            ClashTunnelStore.selectedGroupKey: profile.clashGroup ?? "",
            ClashTunnelStore.selectedNodeKey: node.name,
            ClashTunnelStore.modeKey: library.trafficMode.rawValue
        ]
        manager.protocolConfiguration = provider
        manager.localizedDescription = "LuckyCat · Clash"
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
