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
    private(set) var updatingProfileID: UUID?
    private(set) var library = ProfileLibrary()
    let diagnostics = DiagnosticLog()
    private var libraryLoaded = false
    private(set) var importError: String?
    private(set) var savedEndpoint: String?
    private(set) var traffic: Traffic?
    private(set) var extensionReady: Bool?
    private(set) var issue: Issue?
    var message: String?

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
            stage(try file.read(upToCount: ConfigurationImport.maximumFileSize + 1) ?? Data())
        } catch {
            importError = "无法读取配置文件。"
        }
    }

    func stage(_ data: Data, sourceURL: URL? = nil) {
        guard !busy, !isActive else { return }
        do {
            apply(try ConfigurationImport.parse(data), sourceURL: sourceURL)
        } catch {
            discardImport()
            importError = Self.describeImport(error)
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
            let data = try await RemoteImport.fetch(url)
            let document = try ConfigurationImport.parse(data)
            _ = try RoutePlan.make(mode: .rule, rules: document.rules)
            apply(document, sourceURL: url)
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
        importError = nil
    }

    var defaultImportName: String {
        guard let url = stagedSourceURL else { return "" }
        let file = url.deletingPathExtension().lastPathComponent
        let candidate = file.isEmpty ? (url.host() ?? "") : file
        return String(candidate.prefix(80))
    }

    private func apply(_ document: ImportedConfiguration, sourceURL: URL?) {
        imported = document.nodes
        importedRules = document.rules
        importWarnings = document.warnings
        stagedSourceURL = sourceURL
        importError = nil
    }

    func saveImport(named name: String, selectedNode: String) -> Bool {
        guard libraryLoaded else {
            importError = PrototypeError.profileStorage.localizedDescription
            return false
        }
        guard !busy, !isActive, !imported.isEmpty else { return false }
        let validationPlan: RoutePlan
        do {
            validationPlan = try RoutePlan.make(mode: .rule, rules: importedRules)
        } catch {
            importError = Self.describeImport(error)
            return false
        }
        let plan = (try? RoutePlan.make(mode: library.trafficMode, rules: importedRules)) ?? validationPlan
        let profileID = UUID()
        var nodes: [Profile.Node] = []
        do {
            for node in imported {
                let revision = UUID()
                try TunnelSnapshot.save(
                    node.configuration, profileID: profileID, revision: revision, routePlan: plan
                )
                nodes.append(Profile.Node(
                    id: revision, name: node.name, endpoint: node.configuration.endpoint,
                    clientIPv4: node.configuration.clientIPv4,
                    clientIPv6: node.configuration.clientIPv6,
                    dnsServers: node.configuration.dnsServers
                ))
            }
            guard let selected = nodes.first(where: { $0.name == selectedNode }) else {
                throw PrototypeError.missingConfiguration
            }
            let profile = Profile(
                id: profileID, name: name, nodes: nodes, selectedNodeID: selected.id,
                sourceURL: stagedSourceURL, rules: importedRules.isEmpty ? nil : importedRules
            )
            var updated = library
            updated.profiles.append(profile)
            updated.selectedProfileID = profileID
            try updated.save()
            library = updated
            discardImport()
            message = nil
            record("配置已保存")
            return true
        } catch {
            for node in nodes { TunnelSnapshot.remove(revision: node.id) }
            importError = Self.describeImport(error)
            return false
        }
    }

    func setMode(_ mode: TrafficMode) {
        guard libraryLoaded, !busy, !isActive, library.trafficMode != mode else { return }
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
        busy = true
        updatingProfileID = profile.id
        defer {
            busy = false
            updatingProfileID = nil
        }
        var created: [Profile.Node] = []
        do {
            let data = try await RemoteImport.fetch(sourceURL)
            let document = try ConfigurationImport.parse(data)
            _ = try RoutePlan.make(mode: .rule, rules: document.rules)
            let plan = try RoutePlan.make(mode: library.trafficMode, rules: document.rules)

            for node in document.nodes {
                let revision = UUID()
                try TunnelSnapshot.save(
                    node.configuration, profileID: profile.id, revision: revision, routePlan: plan
                )
                created.append(Profile.Node(
                    id: revision, name: node.name, endpoint: node.configuration.endpoint,
                    clientIPv4: node.configuration.clientIPv4,
                    clientIPv6: node.configuration.clientIPv6,
                    dnsServers: node.configuration.dnsServers
                ))
            }
            guard let selected = created.first(where: { $0.name == profile.selectedNode?.name }) ?? created.first else {
                throw PrototypeError.missingConfiguration
            }
            var updated = library
            updated.profiles[index] = Profile(
                id: profile.id, name: profile.name, nodes: created, selectedNodeID: selected.id,
                sourceURL: sourceURL, rules: document.rules.isEmpty ? nil : document.rules
            )
            try updated.save()
            library = updated

            // Keep the old revisions when the system manager still points at this profile
            // but cannot be rewritten; otherwise a Settings-initiated start would fail.
            var canRemoveOldRevisions = true
            #if !targetEnvironment(simulator)
            do {
                if let manager = try await loadManager(),
                   let provider = manager.protocolConfiguration as? NETunnelProviderProtocol,
                   provider.providerConfiguration?[TunnelSnapshot.profileKey] as? String == profile.id.uuidString {
                    _ = try await save(profile: updated.profiles[index], node: selected, to: manager)
                }
            } catch {
                canRemoveOldRevisions = false
            }
            #endif
            if canRemoveOldRevisions {
                for node in profile.nodes { TunnelSnapshot.remove(revision: node.id) }
            }
            message = document.warnings.isEmpty ? nil : document.warnings.joined(separator: " ")
            issue = nil
            record("配置已更新")
        } catch {
            for node in created { TunnelSnapshot.remove(revision: node.id) }
            message = Self.describeImport(error)
            issue = .configuration
        }
    }

    func select(profileID: UUID) {
        guard libraryLoaded, !busy, !isActive,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        applySelection(index: index, nodeID: nil)
    }

    func select(profileID: UUID, nodeID: UUID) {
        guard libraryLoaded, !busy, !isActive,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }),
              library.profiles[index].nodes.contains(where: { $0.id == nodeID }) else { return }
        applySelection(index: index, nodeID: nodeID)
    }

    private func applySelection(index: Int, nodeID: UUID?) {
        var updated = library
        let alreadySelected = updated.selectedProfileID == updated.profiles[index].id
            && (nodeID == nil || updated.profiles[index].selectedNodeID == nodeID)
        guard !alreadySelected else { return }
        updated.selectedProfileID = updated.profiles[index].id
        if let nodeID { updated.profiles[index].selectedNodeID = nodeID }
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
            for node in profile.nodes { TunnelSnapshot.remove(revision: node.id) }
            message = nil
            issue = nil
            record("配置已删除")
        } catch {
            present(error)
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
            if let profile = library.selectedProfile, let node = profile.selectedNode {
                _ = try TunnelSnapshot.load(profileID: profile.id, revision: node.id)
                let plan = try RoutePlan.make(mode: library.trafficMode, rules: profile.rules ?? [])
                try TunnelSnapshot.saveRoutePlan(plan, profileID: profile.id, revision: node.id)
                selected = try await save(profile: profile, node: node, to: existing ?? NETunnelProviderManager())
            } else if let existing, Self.legacyRevision(of: existing) != nil {
                selected = existing
                if !selected.isEnabled {
                    selected.isEnabled = true
                    try await selected.saveToPreferences()
                }
                try await selected.loadFromPreferences()
            } else {
                throw PrototypeError.missingConfiguration
            }

            adopt(selected)
            if let legacyRevision = Self.legacyRevision(of: selected) {
                _ = try PrototypeStore.load(revision: legacyRevision)
            }
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

    private func save(
        profile: Profile,
        node: Profile.Node,
        to manager: NETunnelProviderManager
    ) async throws -> NETunnelProviderManager {
        let previousRevision = Self.legacyRevision(of: manager)
        let provider = NETunnelProviderProtocol()
        provider.providerBundleIdentifier = try Self.providerIdentifier()
        provider.serverAddress = "LuckyCat"
        provider.providerConfiguration = [
            PrototypeStore.configurationIdentifierKey: PrototypeStore.configurationIdentifier,
            TunnelSnapshot.profileKey: profile.id.uuidString,
            TunnelSnapshot.revisionKey: node.id.uuidString
        ]
        manager.protocolConfiguration = provider
        manager.localizedDescription = "LuckyCat · WireGuard"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if let previousRevision, [.invalid, .disconnected].contains(manager.connection.status) {
            PrototypeStore.remove(revision: previousRevision)
        }
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
        savedEndpoint = manager.flatMap {
            Self.legacyRevision(of: $0) == nil ? nil : $0.protocolConfiguration?.serverAddress
        }
        syncTrafficPolling()
    }

    private func clearConnectionRequest() {
        requestingConnection = false
        connectionRequest = nil
    }

    private static func legacyRevision(of manager: NETunnelProviderManager) -> UUID? {
        let provider = manager.protocolConfiguration as? NETunnelProviderProtocol
        let value = provider?.providerConfiguration?[PrototypeStore.revisionKey] as? String
        return value.flatMap(UUID.init(uuidString:))
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
        return "VPN 操作失败（\(nsError.domain) \(nsError.code)）。"
    }
}
