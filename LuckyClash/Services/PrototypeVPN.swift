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

    private struct ReloadRejected: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var status: NEVPNStatus = .invalid
    private(set) var busy = false
    private(set) var requestingConnection = false
    private(set) var connectionPreparation: String?
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
    private(set) var routeRevision = 0
    private(set) var routeChangesInFlight = 0

    private func beginRouteChange() {
        if latencyTesting && isActive { cancelLatencyTest() }
        routeChangesInFlight += 1
        routeRevision &+= 1
        liveGroups = [:]
        liveGroupsProfileID = nil
    }

    private func finishRouteChange() {
        routeChangesInFlight = max(0, routeChangesInFlight - 1)
        routeRevision &+= 1
        if routeChangesInFlight == 0, status == .connected {
            Task { [weak self] in await self?.refreshLiveGroups() }
        }
    }
    private(set) var latencyProfileID: UUID?
    private(set) var latencyPending: Set<String> = []
    private(set) var latencyResults: [UUID: [String: Int]] = [:]
    private var latencyResultsByURL: [UUID: [String: [String: Int]]] = [:]
    private var latencyPendingURL: String?
    private var latencyRequestID: UUID?
    private(set) var liveGroups: [String: ClashGroupState] = [:]
    private var liveGroupsProfileID: UUID?
    private var liveGroupsRequest = 0
    private(set) var latencyTestedAt: [UUID: Date] = [:]
    private(set) var toast: ToastMessage?
    private var operationMessage: String?
    var message: String? {
        get { operationMessage }
        set {
            operationMessage = newValue
            if let newValue { showToast(newValue) }
        }
    }

    func showToast(_ text: String, isSuccess: Bool = false) {
        toast = ToastMessage(text: text, isSuccess: isSuccess)
    }

    private let latencyTester = ClashLatencyTester.shared
    private var manager: NETunnelProviderManager?
    private var reloadedProfileID: UUID?
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

    func isRunningProfile(_ id: UUID) -> Bool {
        isActive && activeProfileID == id
    }

    func canUpdateProfile(_ id: UUID) -> Bool {
        !busy && !switchingProfile && (!isRunningProfile(id) || (status == .connected && canStop))
    }

    func canRemoveProfile(_ id: UUID) -> Bool {
        !busy && !switchingProfile && !isRunningProfile(id)
    }

    var canSelectProfile: Bool {
        !switchingProfile && (!busy || latencyTesting) && (!isActive || (status == .connected && canStop))
    }

    func importFile(_ url: URL) {
        guard !busy, !switchingProfile else { return }
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
        guard !busy, !switchingProfile else { return }
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
        guard !busy, !switchingProfile else {
            importError = "正在处理其他操作，请稍后重试。"
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

    func saveImport(named name: String, selectedNode: String, customRecipe: CustomProfileRecipe? = nil) -> Bool {
        guard libraryLoaded else {
            importError = PrototypeError.profileStorage.localizedDescription
            return false
        }
        guard !busy, !switchingProfile else { return false }
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
            var prepared = profile
            prepared.customRecipe = customRecipe
            prepared.effectiveRevision = try stageEffectiveConfiguration(for: profile, global: updated.overrides)
            updated.profiles.append(prepared)
            defer {
                if library.profiles.allSatisfy({ $0.id != profile.id }), let revision = prepared.effectiveRevision {
                    ClashTunnelStore.remove(revision: revision)
                }
            }
            if !isActive { updated.selectedProfileID = profileID }
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
        guard libraryLoaded, !busy, !switchingProfile, library.mode != mode else { return }
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
        beginRouteChange()
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishRouteChange() }
            do {
                if mode == .global {
                    guard let profile = self.library.selectedProfile,
                          let name = profile.globalTarget else {
                        throw ClashLiveFailure.rejected("全局模式需要选择一个代理节点。")
                    }
                    try await self.live.select(group: "GLOBAL", name: name)
                }
                try await self.live.setMode(mode)
                self.record("分流模式已应用到当前连接")
                await self.refreshLiveGroups()
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

    func update(_ profile: Profile, sourceURL newSourceURL: URL? = nil, showSuccess: Bool = true) async {
        guard libraryLoaded, canUpdateProfile(profile.id),
              let sourceURL = newSourceURL ?? profile.sourceURL,
              profile.sourceURL != nil,
              let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        if profile.resolvedEngine == .clash {
            await updateClash(profile, index: index, sourceURL: sourceURL, showSuccess: showSuccess)
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
            await updateClash(migrated, index: index, sourceURL: sourceURL, showSuccess: showSuccess)
        } catch {
            message = Self.describeImport(error)
            issue = .configuration
        }
    }

    func exportBackup(password: String) throws -> Data {
        guard libraryLoaded, !busy, !switchingProfile else { throw PrototypeError.profileStorage }
        let payload = try JSONEncoder().encode(ProfileBackup.capture(library))
        return try BackupEncryption.seal(payload, password: password)
    }

    func restoreBackup(_ data: Data, password: String) async throws {
        guard libraryLoaded, !busy, !switchingProfile, !isActive else {
            throw PrototypeError.activeConfiguration
        }
        busy = true
        defer { busy = false }
        let payload = try BackupEncryption.open(data, password: password)
        guard let backup = try? JSONDecoder().decode(ProfileBackup.self, from: payload),
              backup.version == 1, backup.profiles.count <= 1000,
              Set(backup.profiles.map { $0.profile.id }).count == backup.profiles.count,
              backup.selectedProfileID == nil || backup.profiles.contains(where: { $0.profile.id == backup.selectedProfileID }) else {
            throw BackupEncryption.Failure.invalidBackup
        }
        let preferences = try backup.decodedPreferences()
        var restored = ProfileLibrary()
        restored.selectedProfileID = backup.selectedProfileID
        restored.mode = backup.mode
        restored.overrides = backup.overrides
        var clashFiles: [UUID] = []
        var legacyFiles: [UUID] = []
        var committed = false
        defer {
            if !committed {
                for revision in clashFiles { ClashTunnelStore.remove(revision: revision) }
                for revision in legacyFiles { TunnelSnapshot.remove(revision: revision) }
            }
        }
        for entry in backup.profiles {
            let original = entry.profile
            guard !original.nodes.isEmpty, original.nodes.contains(where: { $0.id == original.selectedNodeID }),
                  Set(original.nodes.map(\.id)).count == original.nodes.count else {
                throw BackupEncryption.Failure.invalidBackup
            }
            if original.resolvedEngine == .clash {
                guard let yaml = entry.yaml else { throw BackupEncryption.Failure.invalidBackup }
                _ = try ClashImport.parse(Data(yaml.utf8))
                let revision = UUID()
                try ClashTunnelStore.save(yaml, profileID: original.id, revision: revision)
                clashFiles.append(revision)
                var profile = original
                profile.clashRevision = revision
                profile.effectiveRevision = try stageEffectiveConfiguration(for: profile, global: restored.overrides)
                if let effective = profile.effectiveRevision { clashFiles.append(effective) }
                restored.profiles.append(profile)
            } else {
                guard let saved = entry.legacyNodes, saved.count == original.nodes.count else {
                    throw BackupEncryption.Failure.invalidBackup
                }
                var nodes: [Profile.Node] = []
                var selected: UUID?
                for old in original.nodes {
                    guard let snapshot = saved[old.id] else { throw BackupEncryption.Failure.invalidBackup }
                    try snapshot.configuration.validate()
                    let revision = UUID()
                    try TunnelSnapshot.save(snapshot.configuration, profileID: original.id, revision: revision,
                                            routePlan: snapshot.routePlan)
                    legacyFiles.append(revision)
                    nodes.append(Profile.Node(id: revision, name: old.name, endpoint: old.endpoint, type: old.type,
                                              clientIPv4: old.clientIPv4, clientIPv6: old.clientIPv6, dnsServers: old.dnsServers))
                    if old.id == original.selectedNodeID { selected = revision }
                }
                guard let selected else { throw BackupEncryption.Failure.invalidBackup }
                var profile = Profile(id: original.id, name: original.name, nodes: nodes, selectedNodeID: selected,
                                      sourceURL: original.sourceURL, rules: original.rules, engine: original.engine,
                                      clashRevision: nil, clashGroup: original.clashGroup, clashGroups: original.clashGroups,
                                      subscription: original.subscription, autoUpdate: original.autoUpdate,
                                      clashSelectedMember: original.clashSelectedMember,
                                      updateIntervalOverrideHours: original.updateIntervalOverrideHours)
                profile.clashSelections = original.clashSelections
                profile.overrides = original.overrides
                restored.profiles.append(profile)
            }
        }
        // Restoring creates fresh revision IDs. Remap only references that
        // matched the source at backup time; keep genuinely stale references
        // stale so the user is still prompted to rebuild.
        let originalRevisions = Dictionary(uniqueKeysWithValues: backup.profiles.compactMap { entry in
            entry.profile.clashRevision.map { (entry.profile.id, $0) }
        })
        let restoredRevisions = Dictionary(uniqueKeysWithValues: restored.profiles.compactMap { profile in
            profile.clashRevision.map { (profile.id, $0) }
        })
        for index in restored.profiles.indices {
            guard var recipe = restored.profiles[index].customRecipe else { continue }
            recipe.remapSourceRevisions(original: originalRevisions, restored: restoredRevisions)
            restored.profiles[index].customRecipe = recipe
        }
        #if !targetEnvironment(simulator)
        // A system on-demand rule must not restart the old configuration during restore.
        if let current = try await loadManager() {
            guard [.invalid, .disconnected].contains(current.connection.status) else {
                throw PrototypeError.activeConfiguration
            }
            if current.isOnDemandEnabled {
                current.isOnDemandEnabled = false
                try await current.saveToPreferences()
            }
        }
        #endif
        try restored.save()
        library = restored
        latencyResults.removeAll()
        latencyResultsByURL.removeAll()
        latencyTestedAt.removeAll()
        committed = true
        for key in ProfileBackup.preferenceKeys {
            if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        record("备份已恢复")
    }

    func configurationText(for profile: Profile) throws -> String {
        guard let revision = profile.clashRevision else { throw PrototypeError.missingConfiguration }
        return try ClashTunnelStore.load(profileID: profile.id, revision: revision)
    }

    func effectiveConfiguration(for profile: Profile) throws -> String {
        guard let revision = profile.effectiveRevision ?? profile.clashRevision else {
            throw PrototypeError.missingConfiguration
        }
        let yaml = try ClashTunnelStore.load(profileID: profile.id, revision: revision)
        return ClashModeOverride.apply(library.trafficMode, to: yaml)
    }

    private func stageEffectiveConfiguration(for profile: Profile, global: ConfigurationOverrides?) throws -> UUID? {
        guard profile.resolvedEngine == .clash,
              (global ?? .empty) != .empty || (profile.overrides ?? .empty) != .empty else { return nil }
        let raw = try configurationText(for: profile)
        let text = try ClashOverridePipeline.compose(raw, global: global ?? .empty, profile: profile.overrides ?? .empty)
        let revision = UUID()
        try ClashTunnelStore.save(text, profileID: profile.id, revision: revision)
        return revision
    }

    func saveOverrides(_ overrides: ConfigurationOverrides, profileID: UUID?) async throws {
        guard libraryLoaded, !busy, !switchingProfile,
              profileID.map(canUpdateProfile) ?? (!isActive || (status == .connected && canStop)) else {
            throw ClashLiveFailure.rejected("请等待当前 VPN 操作完成。")
        }
        busy = true
        defer { busy = false }
        let previous = library
        var updated = previous
        if let profileID {
            guard let index = updated.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw PrototypeError.missingConfiguration
            }
            updated.profiles[index].overrides = overrides == .empty ? nil : overrides
        } else {
            updated.overrides = overrides == .empty ? nil : overrides
        }
        let changed = updated.profiles.indices.filter { profileID == nil || updated.profiles[$0].id == profileID }
        var staged: [UUID] = []
        var installed = false
        let runningID = isActive ? activeProfileID : nil
        defer {
            if !installed { for revision in staged { ClashTunnelStore.remove(revision: revision) } }
        }
        for index in changed {
            let revision = try stageEffectiveConfiguration(for: updated.profiles[index], global: updated.overrides)
            updated.profiles[index].effectiveRevision = revision
            if let revision { staged.append(revision) }
        }
        try updated.save()
        library = updated
        installed = true

        var retainPreviousFiles = false
        #if !targetEnvironment(simulator)
        do {
            for index in changed {
                let profile = updated.profiles[index]
                guard let node = profile.selectedNode, profile.resolvedEngine == .clash else { continue }
                let saved: Bool
                if runningID == profile.id {
                    saved = try await activateProfile(profile, node: node)
                } else if !isActive {
                    saved = await persistRestartConfiguration(profile, node: node, replacingOnly: profile.id)
                } else {
                    saved = true
                }
                retainPreviousFiles = retainPreviousFiles || !saved
            }
        } catch let error as ReloadRejected {
            try previous.save()
            library = previous
            installed = false
            throw error
        }
        #endif
        if !retainPreviousFiles {
            for index in changed {
                if let old = previous.profiles[index].effectiveRevision { ClashTunnelStore.remove(revision: old) }
            }
        }
        record("配置覆写已保存")
        showToast(retainPreviousFiles ? "覆写已保存，系统配置将在下次从 App 连接时更新。" : "覆写已保存", isSuccess: true)
    }

    func saveConfiguration(_ text: String, for profile: Profile,
                           customRecipe: CustomProfileRecipe? = nil, name: String? = nil) async -> Bool {
        guard libraryLoaded, canUpdateProfile(profile.id),
              let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        do {
            let document = try ClashImport.parse(Data(text.utf8))
            await updateClash(profile, index: index, sourceURL: profile.sourceURL, replacement: document,
                              customRecipe: customRecipe, replacementName: name)
            return issue == nil
        } catch {
            operationMessage = Self.describeImport(error)
            issue = .configuration
            return false
        }
    }

    /// Rebuild a custom profile from the latest saved source revisions. The
    /// existing profile remains intact if sources or the generated YAML fail.
    func refreshCustomProfile(_ profileID: UUID) async throws {
        guard canUpdateProfile(profileID),
              let profile = library.profiles.first(where: { $0.id == profileID }),
              var recipe = profile.customRecipe else {
            throw ClashLiveFailure.rejected("自定义配置不可更新。")
        }
        let resolved = try CustomProfileDraft.resolveSources(recipe: recipe, profiles: library.profiles,
                                                             excluding: profileID, load: configurationText)
        let yaml = try CustomProfileDraft.build(inventory: resolved.inventory, groups: recipe.groups, rules: recipe.rules)
        recipe.sourceRevisions = resolved.revisions
        guard await saveConfiguration(yaml, for: profile, customRecipe: recipe) else {
            throw ClashLiveFailure.rejected(message ?? "无法保存自定义配置。")
        }
    }

    private func updateClash(
        _ profile: Profile, index: Int, sourceURL: URL?,
        replacement: ImportedConfiguration? = nil, showSuccess: Bool = true,
        customRecipe: CustomProfileRecipe? = nil, replacementName: String? = nil
    ) async {
        if latencyProfileID == profile.id { cancelLatencyTest() }
        busy = true
        updatingProfileID = profile.id
        defer {
            busy = false
            updatingProfileID = nil
        }
        let revision = UUID()
        var installed = false
        var effectiveRevision: UUID?
        do {
            let document: ImportedConfiguration
            var subscription = sourceURL == profile.sourceURL
                ? (profile.subscription ?? Profile.Subscription()) : Profile.Subscription()
            if let replacement {
                document = replacement
            } else {
                guard let sourceURL else { throw PrototypeError.missingConfiguration }
                let response = try await RemoteImport.download(sourceURL)
                let metadata = SubscriptionHeader.parse(headers: response.headers)
                do {
                    document = try ClashImport.parse(response.data)
                } catch {
                    let legacy = try ConfigurationImport.parse(response.data)
                    document = try ClashImport.fromLegacy(legacy)
                }
                Self.merge(metadata.subscription, into: &subscription)
                subscription.lastUpdated = Date()
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
            var updated = library
            updated.profiles[index] = Profile(
                id: profile.id, name: profile.name, nodes: nodes, selectedNodeID: selected.id,
                sourceURL: sourceURL, rules: nil, engine: .clash,
                clashRevision: revision,
                clashGroup: synthesizedNode
                    ? nil
                    : Self.selectableGroup(for: selected, in: document.groups),
                clashGroups: document.groups,
                subscription: replacement == nil ? subscription : profile.subscription, autoUpdate: profile.autoUpdate,
                clashSelectedMember: profile.clashGroup.flatMap { group in
                    document.groups.first(where: { $0.name == group && $0.isSelectable })
                        .flatMap { $0.members.contains(profile.clashSelectedMember ?? "") ? profile.clashSelectedMember : nil }
                }
            )
            let newGroups = Dictionary(document.groups.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            updated.profiles[index].clashSelections = profile.groupSelections.filter { name, member in
                guard let group = newGroups[name], group.isSelectable || group.canPin else { return false }
                return group.members.contains(member) || group.usesProviders == true
            }
            if let group = profile.clashGroup, let member = updated.profiles[index].clashSelections?[group] {
                updated.profiles[index].selectGroup(group, member: member)
            }
            updated.profiles[index].updateIntervalOverrideHours = profile.updateIntervalOverrideHours
            if updated.profiles[index].clashSelectedMember != nil {
                updated.profiles[index].clashGroup = profile.clashGroup
            }
            updated.profiles[index].overrides = profile.overrides
            // Raw YAML edits intentionally clear the recipe: the visual inputs
            // no longer necessarily describe the edited document.
            updated.profiles[index].customRecipe = replacement == nil ? profile.customRecipe : customRecipe
            if let replacementName { updated.profiles[index].name = replacementName }
            effectiveRevision = try stageEffectiveConfiguration(
                for: updated.profiles[index], global: updated.overrides
            )
            updated.profiles[index].effectiveRevision = effectiveRevision
            try updated.save()
            library = updated
            installed = true
            clearLatencyResults(for: profile.id)

            var canRemoveOldRevisions = true
            #if !targetEnvironment(simulator)
            if isRunningProfile(profile.id) {
                do {
                    canRemoveOldRevisions = try await activateProfile(updated.profiles[index], node: selected)
                } catch let error as ReloadRejected {
                    updated.profiles[index] = profile
                    try updated.save()
                    library = updated
                    installed = false
                    throw error
                }
            } else if !isActive {
                canRemoveOldRevisions = await persistRestartConfiguration(
                    updated.profiles[index], node: selected, replacingOnly: profile.id
                )
            }
            #endif
            if canRemoveOldRevisions, let previous = profile.clashRevision {
                ClashTunnelStore.remove(revision: previous)
            }
            if canRemoveOldRevisions, let previous = profile.effectiveRevision {
                ClashTunnelStore.remove(revision: previous)
            }
            if !canRemoveOldRevisions {
                message = "配置已保存，下次从 App 连接时应用到系统 VPN 设置。"
            } else if document.warnings.isEmpty {
                operationMessage = nil
                if showSuccess {
                    showToast(replacement == nil ? "订阅已更新" : "配置已保存", isSuccess: true)
                }
            } else {
                message = document.warnings.joined(separator: " ")
            }
            issue = nil
            record("配置已更新")
        } catch {
            if !installed {
                ClashTunnelStore.remove(revision: revision)
                if let effectiveRevision { ClashTunnelStore.remove(revision: effectiveRevision) }
            }
            let failure = (error as? ReloadRejected)?.localizedDescription ?? Self.describeImport(error)
            operationMessage = failure
            if replacement == nil {
                if let remoteFailure = error as? RemoteImport.Failure, case .status(let code) = remoteFailure {
                    showToast("「\(profile.name)」更新失败（HTTP \(code)）")
                } else {
                    showToast("「\(profile.name)」更新失败。\(failure)")
                }
            }
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
        var migrated = Profile(
            id: profile.id, name: profile.name, nodes: migratedNodes,
            selectedNodeID: selected.id, sourceURL: profile.sourceURL, rules: nil,
            engine: .clash, clashRevision: revision, clashGroup: group,
            clashGroups: converted.groups,
            subscription: profile.subscription, autoUpdate: profile.autoUpdate
        )
        var updated = library
        migrated.overrides = profile.overrides
        migrated.effectiveRevision = try stageEffectiveConfiguration(for: migrated, global: updated.overrides)
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
        guard libraryLoaded, canSelectProfile,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard library.selectedProfileID != profileID else { return }
        guard isActive else {
            applySelection(index: index, nodeID: nil)
            return
        }
        let profile = library.profiles[index]
        let previousID = library.selectedProfileID
        switchingProfile = true
        beginRouteChange()
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.switchingProfile = false
                self.finishRouteChange()
            }
            self.cancelLatencyTest()
            self.applySelection(index: index, nodeID: nil)
            guard self.library.selectedProfileID == profileID else { return }
            do {
                guard let node = profile.selectedNode else {
                    throw ReloadRejected(message: PrototypeError.missingConfiguration.localizedDescription)
                }
                if try await !self.activateProfile(profile, node: node) {
                    self.message = "已切换配置，下次从 App 连接时应用到系统 VPN 设置。"
                }
            } catch let error as ReloadRejected {
                var restored = self.library
                restored.selectedProfileID = previousID
                do {
                    try restored.save()
                    self.library = restored
                    self.present(error)
                } catch { self.present(error) }
            } catch {
                self.present(error, inConnection: true)
            }
        }
    }

    func select(profileID: UUID, nodeID: UUID, group: String? = nil) {
        guard libraryLoaded, (!busy || latencyTesting), !switchingProfile,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }),
              let node = library.profiles[index].nodes.first(where: { $0.id == nodeID }) else { return }
        if let group = (library.profiles[index].clashGroups ?? []).first(where: {
            group == nil ? ($0.isSelectable && $0.members.contains(node.name)) : $0.name == group
        }) {
            selectMember(profileID: profileID, group: group, member: node.name)
            return
        }
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
        guard group.isSelectable || group.canPin, members(for: group, profileID: profileID).contains(member) else { return }
        changeGroup(profileID: profileID, group: group, member: member)
    }

    func unfixGroup(profileID: UUID, group: ClashImportGroup) {
        guard group.canPin else { return }
        changeGroup(profileID: profileID, group: group, member: nil)
    }

    private func changeGroup(profileID: UUID, group: ClashImportGroup, member: String?) {
        guard libraryLoaded, !busy, canSwitchNodes(for: profileID),
              let index = library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var updated = library
        updated.selectedProfileID = profileID
        updated.profiles[index].selectGroup(group.name, member: member)
        guard isActive else {
            do {
                try updated.save()
                library = updated
                record("切换策略")
                publishWidgetStatus()
            } catch { present(error) }
            return
        }
        guard status == .connected else { return }
        busy = true
        beginRouteChange()
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.finishRouteChange()
            }
            do {
                if let member {
                    try await self.live.select(group: group.name, name: member)
                    if self.library.trafficMode == .global {
                        try await self.live.select(group: "GLOBAL", name: member)
                    }
                } else {
                    if self.library.trafficMode == .global {
                        try await self.live.select(group: "GLOBAL", name: group.name)
                    }
                    try await self.live.unfix(group: group.name)
                }
                try updated.save()
                self.library = updated
                self.issue = nil
                self.record(member == nil ? "恢复自动选择" : "切换策略")
                self.publishWidgetStatus()
                if UserDefaults.standard.object(forKey: "closeConnectionsOnNodeSwitch") as? Bool ?? true {
                    try await self.live.closeAllConnections()
                }
            } catch { self.present(error) }
            await self.refreshLiveGroups()
        }
    }

    /// The active profile's node can be switched on the running core; any
    /// other profile still needs a reconnect.
    func canSwitchNodes(for profileID: UUID) -> Bool {
        guard (!busy || latencyTesting), !switchingProfile else { return false }
        guard isActive else { return true }
        return activeProfileID == profileID
    }

    private var activeProfileID: UUID? {
        if let reloadedProfileID { return reloadedProfileID }
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
        beginRouteChange()
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishRouteChange() }
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
        guard libraryLoaded, canRemoveProfile(profile.id),
              let profile = library.profiles.first(where: { $0.id == profile.id }) else { return }
        busy = true
        defer { busy = false }
        do {
            #if !targetEnvironment(simulator)
            let storedManager = try await loadManager()
            let storedConfiguration = (storedManager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            guard !isRunningProfile(profile.id) else { throw PrototypeError.activeConfiguration }
            if storedConfiguration?[ClashTunnelStore.profileKey] as? String == profile.id.uuidString,
               let storedManager {
                guard !isActive, [.invalid, .disconnected].contains(storedManager.connection.status) else {
                    throw PrototypeError.activeConfiguration
                }
                try await storedManager.removeFromPreferences()
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
            clearLatencyResults(for: profile.id)
            if profile.resolvedEngine == .clash {
                if let revision = profile.effectiveRevision { ClashTunnelStore.remove(revision: revision) }
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
        guard libraryLoaded, !busy, !switchingProfile,
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

    func setUpdateInterval(_ hours: Int?, for profileID: UUID) {
        guard libraryLoaded, !busy, !switchingProfile,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var updated = library
        updated.profiles[index].updateIntervalOverrideHours = hours
        do {
            try updated.save()
            library = updated
        } catch { present(error) }
    }

    func rename(profileID: UUID, to newName: String) {
        let name = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard libraryLoaded, !busy, !switchingProfile, !name.isEmpty,
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

    func latencyValue(for nodeName: String, profileID: UUID, testURL: String? = nil) -> Int? {
        let url = effectiveTestURL(testURL, profileID: profileID)
        let value = latencyResultsByURL[profileID]?[url]?[nodeName]
            ?? (latencyResultsByURL[profileID] == nil ? latencyResults[profileID]?[nodeName] : nil)
        guard let value, value >= 0 else { return nil }
        return value
    }

    func cancelLatencyTest() {
        guard latencyTesting else { return }
        latencyRequestID = nil
        latencyTester.cancel()
        live.cancelURLTests()
        message = "正在停止延迟测试…"
    }

    func refreshLiveGroups() async {
        guard status == .connected, routeChangesInFlight == 0, let profileID = activeProfileID else { return }
        let revision = library.profiles.first { $0.id == profileID }?.clashRevision
        let route = routeRevision
        let statusChange = statusChangedAt
        liveGroupsRequest &+= 1
        let request = liveGroupsRequest
        do {
            let groups = try await live.groups()
            guard !Task.isCancelled, status == .connected, activeProfileID == profileID,
                  routeChangesInFlight == 0, routeRevision == route, statusChangedAt == statusChange,
                  liveGroupsRequest == request,
                  library.profiles.first(where: { $0.id == profileID })?.clashRevision == revision else { return }
            if liveGroupsProfileID != profileID || liveGroups != groups {
                liveGroups = groups
                liveGroupsProfileID = profileID
                publishWidgetStatus()
            }
        } catch {
            // Keep the last successful state during a transient socket failure.
        }
    }

    func members(for group: ClashImportGroup, profileID: UUID) -> [String] {
        guard isRunningProfile(profileID), liveGroupsProfileID == profileID else { return group.members }
        return liveGroups[group.name]?.all ?? group.members
    }

    func selectedMember(in group: String, profile: Profile) -> String? {
        if isRunningProfile(profile.id), liveGroupsProfileID == profile.id,
           let current = liveGroups[group]?.now, !current.isEmpty { return current }
        return profile.groupSelections[group]
    }

    func fixedMember(in group: String, profile: Profile) -> String? {
        if isRunningProfile(profile.id), liveGroupsProfileID == profile.id, let state = liveGroups[group] {
            return state.fixed.flatMap { $0.isEmpty ? nil : $0 }
        }
        return profile.groupSelections[group]
    }

    func strategyChain(from root: String, profile: Profile) -> [String] {
        var chain = [root]
        var visited: Set<String> = [root]
        while let group = chain.last,
              let member = selectedMember(in: group, profile: profile),
              visited.insert(member).inserted {
            chain.append(member)
        }
        return chain
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
        if isActive, (activeProfileID != profile.id || status != .connected) {
            message = "请等待当前配置连接完成后再测速。"
            return
        }
        let groups = (profile.clashGroups ?? []).map { group in
            ClashImportGroup(name: group.name, type: group.type, members: members(for: group, profileID: profile.id), testURL: group.testURL)
        }
        let dynamicNames = isRunningProfile(profile.id) && liveGroupsProfileID == profile.id
            ? liveGroups.values.flatMap { $0.all ?? [] } : []
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
        guard let revision = profile.effectiveRevision ?? profile.clashRevision,
              let yaml = try? ClashTunnelStore.load(profileID: profile.id, revision: revision) else {
            message = "找不到该配置的本地文件，请更新或重新导入。"
            issue = .configuration
            return
        }
        busy = true
        latencyTesting = true
        latencyProfileID = profile.id
        latencyPending = Set(names)
        let requestID = UUID()
        latencyRequestID = requestID
        let testURL = effectiveTestURL(testURL, profileID: profile.id)
        latencyPendingURL = testURL
        if latencyResultsByURL[profile.id]?[testURL] == nil {
            latencyResultsByURL[profile.id, default: [:]][testURL] = [:]
        }
        message = nil
        issue = nil
        record("开始延迟测试")
        defer {
            busy = false
            latencyTesting = false
            latencyProfileID = nil
            latencyPending = []
            latencyPendingURL = nil
            if latencyRequestID == requestID { latencyRequestID = nil }
            if message == "正在停止延迟测试…" { message = nil }
        }

        do {
            let results = try await latencyTester.measure(
                configuration: yaml, nodes: names, testURL: testURL, timeout: delayTestTimeout
            ) { [weak self] name, delay in
                Task { @MainActor [weak self] in
                    self?.applyLatency(name, delay: delay, profileID: profile.id, testURL: testURL, requestID: requestID)
                }
            }
            guard latencyRequestID == requestID else { return }
            for (name, delay) in results {
                applyLatency(name, delay: delay, profileID: profile.id, testURL: testURL, requestID: requestID)
            }
            latencyTestedAt[profile.id] = Date()
            if !names.allSatisfy({ results[$0] != nil }) {
                message = "部分节点没有返回延迟。"
            }
            record("延迟测试完成")
        } catch {
            guard latencyRequestID == requestID else { return }
            message = error.localizedDescription
            issue = Self.issue(for: error)
            record("延迟测试失败")
        }
    }

    private func testLatencyLive(_ profile: Profile, names: [String], testURL: String?) async {

        latencyTesting = true
        latencyProfileID = profile.id
        latencyPending = Set(names)
        let requestID = UUID()
        latencyRequestID = requestID
        let testURL = effectiveTestURL(testURL, profileID: profile.id)
        latencyPendingURL = testURL
        if latencyResultsByURL[profile.id]?[testURL] == nil {
            latencyResultsByURL[profile.id, default: [:]][testURL] = [:]
        }
        message = nil
        issue = nil
        record("开始延迟测试")
        defer {
            latencyTesting = false
            latencyProfileID = nil
            latencyPending = []
            latencyPendingURL = nil
            if latencyRequestID == requestID { latencyRequestID = nil }
            if message == "正在停止延迟测试…" { message = nil }
        }

        do {
            let results = try await live.urlTest(
                names: names, testURL: testURL, timeout: delayTestTimeout
            ) { [weak self] name, delay in
                Task { @MainActor [weak self] in
                    self?.applyLatency(name, delay: delay, profileID: profile.id, testURL: testURL, requestID: requestID)
                }
            }
            guard latencyRequestID == requestID else { return }
            for (name, delay) in results {
                applyLatency(name, delay: delay, profileID: profile.id, testURL: testURL, requestID: requestID)
            }
            latencyTestedAt[profile.id] = Date()
            if !names.allSatisfy({ results[$0] != nil }) {
                message = "部分节点没有返回延迟。"
            }
            record("延迟测试完成")
        } catch {
            guard latencyRequestID == requestID else { return }
            message = error.localizedDescription
            record("延迟测试失败")
        }
    }

    private var delayTestTimeout: Int {
        let stored = UserDefaults.standard.object(forKey: ClashDelayRequest.timeoutKey) as? Int
        return min(15_000, max(500, stored ?? ClashDelayRequest.defaultTimeout))
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

    private func applyLatency(_ name: String, delay: Int, profileID: UUID, testURL: String, requestID: UUID) {
        guard latencyRequestID == requestID, latencyPending.contains(name),
              latencyProfileID == profileID, latencyPendingURL == testURL else { return }
        latencyPending.remove(name)
        latencyResults[profileID, default: [:]][name] = delay
        latencyResultsByURL[profileID, default: [:]][testURL, default: [:]][name] = delay
    }

    private func clearLatencyResults(for profileID: UUID) {
        latencyResults.removeValue(forKey: profileID)
        latencyResultsByURL.removeValue(forKey: profileID)
        latencyTestedAt.removeValue(forKey: profileID)
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
        guard libraryLoaded, !busy, !switchingProfile else { return }
        let profiles = library.profiles.filter { $0.sourceURL != nil }
        var failures: [String] = []
        var warnings: [String] = []
        var updatedCount = 0
        for profile in profiles {
            guard canUpdateProfile(profile.id) else { continue }
            await update(profile, showSuccess: false)
            if issue != nil {
                failures.append("\(profile.name)：\(message ?? "更新失败")")
            } else {
                updatedCount += 1
                if let message { warnings.append("\(profile.name)：\(message)") }
            }
        }
        let notices = failures + warnings
        if !notices.isEmpty {
            message = notices.joined(separator: "\n")
        } else if updatedCount > 0 {
            showToast("已更新 \(updatedCount) 个订阅", isSuccess: true)
        }
        issue = failures.isEmpty ? nil : .configuration
    }

    func updateDueProfiles() async {
        guard libraryLoaded, !busy, !switchingProfile else { return }
        let now = Date()
        for id in library.profiles.map(\.id) {
            guard canUpdateProfile(id) else { continue }
            guard let profile = library.profiles.first(where: { $0.id == id }),
                  profile.isAutoUpdateDue(at: now) else { continue }
            await update(profile, showSuccess: false)
        }
    }

    func refresh() async {
        diagnostics.importTunnelEvents()
        if !libraryLoaded {
            do {
                library = try ProfileLibrary.load()
                libraryLoaded = true
            } catch {
                message = "无法读取本地配置列表。"
            }
        }
        #if targetEnvironment(simulator)
        VPNWidgetStatus.disconnected.publish()
        #else
        guard !busy, !switchingProfile, !requestingConnection else { return }
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
        guard !busy, !switchingProfile else { return }
        await connectSelectedProfile()
    }

    private func connectSelectedProfile(_ requestedProfile: Profile? = nil) async {
        #if targetEnvironment(simulator)
        record("模拟器连接请求")
        message = PrototypeError.simulator.localizedDescription
        #else
        guard !isActive else { return }
        let wasBusy = busy
        busy = true
        connectionPreparation = "正在准备连接…"
        defer {
            connectionPreparation = nil
            busy = wasBusy
        }
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
            if let selectedProfile = requestedProfile ?? library.selectedProfile {
                guard let index = library.profiles.firstIndex(where: { $0.id == selectedProfile.id }) else {
                    throw PrototypeError.missingConfiguration
                }
                var profile = selectedProfile
                if profile.resolvedEngine == .wireGuard {
                    connectionPreparation = "正在迁移旧版 WireGuard 配置…"
                    profile = try await migrateLegacy(
                        profile, index: index, rewriteManager: false
                    )
                    connectionPreparation = "正在准备连接…"
                }
                guard let node = profile.selectedNode else {
                    throw PrototypeError.missingConfiguration
                }
                let revision = profile.effectiveRevision ?? profile.clashRevision ?? node.id
                let yaml = try ClashTunnelStore.load(profileID: profile.id, revision: revision)
                if ClashGeodata.isRequired(yaml) {
                    connectionPreparation = "正在准备 GeoIP 数据…"
                    try await ClashGeodata.ensure(yaml: yaml, allowAutomaticUpdate: true)
                    connectionPreparation = "正在准备连接…"
                }
                selected = try await saveClash(
                    profile: profile, node: node, to: existing ?? NETunnelProviderManager(), applyNetworkOptions: true
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
            connectionPreparation = nil
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
                        self.operationMessage = "iOS 未启动连接，请检查系统 VPN 设置。"
                        self.issue = .permission
                        self.network.stop()
                    }
                }
            }
        } catch {
            present(error, inConnection: true)
            if !isActive {
                network.stop()
            }
        }
        #endif
    }

    func disconnect() {
        guard !busy, !switchingProfile, canStop else { return }
        guard UserDefaults.standard.bool(forKey: TunnelNetworkOptions.onDemand) else {
            stopConnection()
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await suspendOnDemand()
                stopConnection()
            } catch { present(error, inConnection: true) }
        }
    }

    private func suspendOnDemand() async throws {
        guard let stored = try await loadManager(), stored.isOnDemandEnabled else { return }
        stored.isOnDemandEnabled = false
        try await stored.saveToPreferences()
    }

    func applyOnDemandSettings() async throws {
        #if !targetEnvironment(simulator)
        guard !busy, !switchingProfile else { throw ClashLiveFailure.unavailable }
        busy = true
        defer { busy = false }
        let enabled = UserDefaults.standard.bool(forKey: TunnelNetworkOptions.onDemand)
        if let stored = try await loadManager() {
            configureOnDemand(stored, enabled: enabled)
            try await stored.saveToPreferences()
        } else if enabled, let profile = library.selectedProfile, let node = profile.selectedNode {
            // Stage prerequisites before the OS can automatically start the configuration.
            let yaml = try effectiveConfiguration(for: profile)
            if ClashGeodata.isRequired(yaml) { try await ClashGeodata.ensure(yaml: yaml) }
            let stored = try await saveClash(
                profile: profile, node: node, to: NETunnelProviderManager(), applyNetworkOptions: true
            )
            adopt(stored)
        } else if enabled {
            throw PrototypeError.missingConfiguration
        }
        #endif
    }

    private func configureOnDemand(_ manager: NETunnelProviderManager, enabled: Bool) {
        let networks = TunnelNetworkOptions.trustedSSIDs
        var rules: [NEOnDemandRule] = []
        if !networks.isEmpty {
            let disconnect = NEOnDemandRuleDisconnect()
            disconnect.interfaceTypeMatch = .wiFi
            disconnect.ssidMatch = networks
            rules.append(disconnect)
        }
        rules.append(NEOnDemandRuleConnect())
        manager.onDemandRules = rules
        manager.isOnDemandEnabled = enabled
    }

    private func stopConnection() {
        guard canStop else { return }
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
        if current == .disconnected || current == .invalid {
            reloadedProfileID = nil
            if !liveGroups.isEmpty { liveGroups = [:] }
            liveGroupsProfileID = nil
        }
        if current != previous {
            statusChangedAt = UUID()
            status = current
            publishWidgetStatus()
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
            diagnostics.importTunnelEvents()
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
        present(error, inConnection: true)
        record("断开错误码 \(error.code)")
    }

    func freeTunnelMemory() {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected else { return }
        let request = TunnelMemoryMessage.Request(version: TunnelStatusMessage.version, id: UUID(), freeMemory: true)
        do {
            let data = try JSONEncoder().encode(request)
            try session.sendProviderMessage(data) { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let data, let reply = try? JSONDecoder().decode(TunnelMemoryMessage.Reply.self, from: data),
                          reply.version == request.version, reply.id == request.id else {
                        self.message = "无法释放内核内存。"
                        return
                    }
                    self.showToast("已请求释放内存", isSuccess: true)
                }
            }
        } catch { message = error.localizedDescription }
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
        if let runningProfileID = reply.runningProfileID, !switchingProfile, !busy {
            reloadedProfileID = runningProfileID
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
                await self.refreshLiveGroups()
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

    /// Returns whether the system configuration also points at the new revision.
    private func activateProfile(_ profile: Profile, node: Profile.Node) async throws -> Bool {
        beginRouteChange()
        defer { finishRouteChange() }
        let selection = tunnelSelection(profile: profile, node: node)
        if selection.mode == .global, (selection.node ?? "").isEmpty {
            throw ReloadRejected(message: "全局模式需要选择一个代理节点。")
        }
        do {
            let yaml = try ClashTunnelStore.load(profileID: selection.profileID, revision: selection.revision)
            if ClashGeodata.isRequired(yaml) { try await ClashGeodata.ensure(yaml: yaml) }
        } catch {
            throw ReloadRejected(message: Self.describe(error))
        }
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected, canStop else {
            return await persistRestartConfiguration(profile, node: node)
        }
        let reply = await sendReload(selection, to: session)
        switch reply?.outcome {
        case .applied:
            reloadedProfileID = profile.id
            diagnosticRequest = nil
            liveGroups = [:]
            record("配置已热重载")
            let persisted = await persistRestartConfiguration(profile, node: node)
            await refreshLiveGroups()
            return persisted
        case .rejected:
            throw ReloadRejected(message: reply?.message ?? "内核拒绝新配置。")
        case .restart, nil:
            guard manager?.connection === session,
                  [.connected, .reasserting].contains(session.status), canStop else {
                return await persistRestartConfiguration(profile, node: node)
            }
            record("配置热重载需要重连")
            try await suspendOnDemand()
            stopConnection()
            let deadline = ContinuousClock.now + .seconds(30)
            while isActive, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(150))
                await updateStatus()
            }
            guard !isActive else {
                throw ClashLiveFailure.rejected("断开当前连接超时，请手动断开后重试。")
            }
            await connectSelectedProfile(profile)
            guard isActive else {
                throw ClashLiveFailure.rejected(message ?? "重连失败，请手动连接。")
            }
            return true
        }
    }

    private func sendReload(
        _ selection: TunnelReloadMessage.Selection, to session: NETunnelProviderSession
    ) async -> TunnelReloadMessage.Reply? {
        let request = TunnelReloadMessage.Request(version: TunnelReloadMessage.version, id: UUID(), selection: selection)
        guard let data = try? JSONEncoder().encode(request),
              data.count <= TunnelReloadMessage.maximumBytes else { return nil }
        let (responses, continuation) = AsyncStream<Data?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        do {
            try session.sendProviderMessage(data) { response in
                continuation.yield(response)
                continuation.finish()
            }
        } catch { return nil }
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            continuation.finish()
        }
        defer {
            timeout.cancel()
            continuation.finish()
        }
        for await response in responses {
            guard let response,
                  let reply = try? JSONDecoder().decode(TunnelReloadMessage.Reply.self, from: response),
                  reply.version == request.version, reply.id == request.id else { return nil }
            return reply
        }
        return nil
    }

    private func persistRestartConfiguration(
        _ profile: Profile, node: Profile.Node, replacingOnly expectedProfileID: UUID? = nil
    ) async -> Bool {
        do {
            guard let manager = try await loadManager() else { return true }
            if let expectedProfileID {
                let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
                guard configuration?[ClashTunnelStore.profileKey] as? String == expectedProfileID.uuidString else {
                    return true
                }
            }
            _ = try await saveClash(profile: profile, node: node, to: manager)
            return true
        } catch {
            record("保存系统 VPN 配置失败")
            return false
        }
    }

    private func tunnelSelection(profile: Profile, node: Profile.Node) -> TunnelReloadMessage.Selection {
        .init(
            profileID: profile.id,
            revision: profile.effectiveRevision ?? profile.clashRevision ?? node.id,
            group: profile.clashGroup,
            node: profile.globalTarget,
            mode: library.trafficMode,
            selections: profile.groupSelections
        )
    }

    private func saveClash(
        profile: Profile,
        node: Profile.Node,
        to manager: NETunnelProviderManager,
        applyNetworkOptions: Bool = false
    ) async throws -> NETunnelProviderManager {
        let existingProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol
        let provider = (existingProtocol?.copy() as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        let selection = tunnelSelection(profile: profile, node: node)
        provider.providerBundleIdentifier = try Self.providerIdentifier()
        provider.serverAddress = "LuckyClash"
        let profileSettings: [String: Any] = [
            PrototypeStore.configurationIdentifierKey: PrototypeStore.configurationIdentifier,
            ClashTunnelStore.engineKey: ClashTunnelStore.engineClash,
            ClashTunnelStore.profileKey: selection.profileID.uuidString,
            ClashTunnelStore.revisionKey: selection.revision.uuidString,
            ClashTunnelStore.selectedGroupKey: selection.group ?? "",
            ClashTunnelStore.selectedNodeKey: selection.node ?? "",
            ClashTunnelStore.modeKey: selection.mode?.rawValue ?? "",
            ClashTunnelStore.selectionsKey: selection.groupSelections
        ]
        var configuration = (applyNetworkOptions ? nil : existingProtocol?.providerConfiguration) ?? [:]
        configuration.merge(profileSettings) { _, new in new }
        if applyNetworkOptions {
            let defaults = UserDefaults.standard
            configuration[TunnelNetworkOptions.ipv6Mode] = defaults.string(forKey: TunnelNetworkOptions.ipv6Mode) ?? "config"
            configuration[TunnelNetworkOptions.queryMode] = defaults.string(forKey: TunnelNetworkOptions.queryMode) ?? "config"
            configuration[TunnelNetworkOptions.mtu] = defaults.integer(forKey: TunnelNetworkOptions.mtu)
            configuration[TunnelNetworkOptions.bypassPrivate] = defaults.bool(forKey: TunnelNetworkOptions.bypassPrivate)
            provider.includeAllNetworks = defaults.bool(forKey: TunnelNetworkOptions.includeAllNetworks)
            provider.excludeLocalNetworks = defaults.bool(forKey: TunnelNetworkOptions.bypassPrivate)
            configureOnDemand(manager, enabled: defaults.bool(forKey: TunnelNetworkOptions.onDemand))
        }
        provider.providerConfiguration = configuration
        manager.protocolConfiguration = provider
        manager.localizedDescription = "LuckyClash"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }

    private func record(_ event: String) {
        diagnostics.append(event)
    }

    private func present(_ error: Error, inConnection: Bool = false) {
        issue = Self.issue(for: error)
        if inConnection, issue == .permission, library.selectedProfile != nil {
            operationMessage = Self.describe(error)
        } else {
            message = Self.describe(error)
        }
    }

    static func issue(for error: Error) -> Issue? {
        if error is ClashImport.Failure || error is ReloadRejected { return .configuration }
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
        publishWidgetStatus()
        syncTrafficPolling()
        syncNetworkMonitoring()
    }

    private func publishWidgetStatus() {
        let widgetStatus: VPNWidgetStatus
        switch status {
        case .invalid, .disconnected: widgetStatus = .disconnected
        case .connecting, .reasserting: widgetStatus = .connecting
        case .connected: widgetStatus = .connected
        case .disconnecting: widgetStatus = .disconnecting
        @unknown default: widgetStatus = .unknown
        }
        let profile = library.profiles.first { $0.id == activeProfileID }
        let group = profile?.clashGroup
        let node = group.flatMap { name in
            profile.flatMap { selectedMember(in: name, profile: $0) }
        } ?? profile?.selectedOutboundName
        widgetStatus.publish(group: group, node: node)
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
