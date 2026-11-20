import Foundation
import NetworkExtension
import Observation

@Observable
final class PrototypeVPN {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var busy = false
    private(set) var requestingConnection = false
    private(set) var imported: [ImportedNode] = []
    private(set) var library = ProfileLibrary()
    private(set) var diagnostics: [String] = []
    private var libraryLoaded = false
    private(set) var importError: String?
    private(set) var savedEndpoint: String?
    var message: String?

    private var manager: NETunnelProviderManager?
    private var connectionRequest: UUID?
    private var statusChangedAt = UUID()
    private var stopRequest: UUID?
    private var diagnosticRequest: UUID?

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

    func stage(_ data: Data) {
        guard !busy, !isActive else { return }
        discardImport()
        do {
            imported = try ConfigurationImport.parse(data)
        } catch {
            importError = error.localizedDescription
        }
    }

    func discardImport() {
        imported = []
        importError = nil
    }

    func saveImport(named name: String, selectedNode: String) -> Bool {
        guard libraryLoaded else {
            importError = PrototypeError.profileStorage.localizedDescription
            return false
        }
        guard !busy, !isActive, !imported.isEmpty else { return false }
        let profileID = UUID()
        var nodes: [Profile.Node] = []
        do {
            for node in imported {
                let revision = UUID()
                try TunnelSnapshot.save(node.configuration, profileID: profileID, revision: revision)
                nodes.append(Profile.Node(id: revision, name: node.name, endpoint: node.configuration.endpoint))
            }
            guard let selected = nodes.first(where: { $0.name == selectedNode }) else {
                throw PrototypeError.missingConfiguration
            }
            let profile = Profile(id: profileID, name: name, nodes: nodes, selectedNodeID: selected.id)
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
            importError = Self.describe(error)
            return false
        }
    }

    func select(profileID: UUID, nodeID: UUID) {
        guard libraryLoaded, !busy, !isActive,
              let index = library.profiles.firstIndex(where: { $0.id == profileID }),
              library.profiles[index].nodes.contains(where: { $0.id == nodeID }) else { return }
        var updated = library
        updated.selectedProfileID = profileID
        updated.profiles[index].selectedNodeID = nodeID
        do {
            try updated.save()
            library = updated
            message = nil
        } catch {
            message = Self.describe(error)
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
            record("配置已删除")
        } catch {
            message = Self.describe(error)
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
            message = Self.describe(error)
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

        do {
            let existing = try await loadManager()
            adopt(existing)
            guard !isActive else { return }
            let selected: NETunnelProviderManager
            if let profile = library.selectedProfile, let node = profile.selectedNode {
                _ = try TunnelSnapshot.load(profileID: profile.id, revision: node.id)
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
                    }
                }
            }
        } catch {
            message = Self.describe(error)
        }
        #endif
    }

    func disconnect() {
        guard !busy, canStop else { return }
        guard let connection = manager?.connection else { return }
        clearConnectionRequest()
        message = nil
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
            if current == .connected { queryExtensionStatus() }
        }
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
        message = Self.describe(error)
        record("断开错误码 \(error.code)")
    }

    private func queryExtensionStatus() {
        guard diagnosticRequest == nil, let session = manager?.connection as? NETunnelProviderSession else { return }
        let id = UUID()
        diagnosticRequest = id
        do {
            let request = TunnelStatusMessage.Request(version: TunnelStatusMessage.version, id: id)
            let data = try JSONEncoder().encode(request)
            try session.sendProviderMessage(data) { [weak self] response in
                Task { @MainActor [weak self] in
                    let reply = response.flatMap { try? JSONDecoder().decode(TunnelStatusMessage.Reply.self, from: $0) }
                    let ready = reply.flatMap { $0.id == id && $0.version == TunnelStatusMessage.version ? $0.ready : nil }
                    self?.completeDiagnostic(id, ready: ready)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.completeDiagnostic(id, ready: nil)
            }
        } catch {
            completeDiagnostic(id, ready: nil)
        }
    }

    private func completeDiagnostic(_ id: UUID, ready: Bool?) {
        guard diagnosticRequest == id else { return }
        diagnosticRequest = nil
        guard status == .connected else { return }
        switch ready {
        case true?: record("扩展已就绪")
        case false?: record("扩展未就绪")
        case nil: record("扩展诊断暂不可用")
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
        diagnostics.append("\(Date.now.formatted(.iso8601))  \(event)")
        if diagnostics.count > 32 { diagnostics.removeFirst() }
    }

    private func adopt(_ manager: NETunnelProviderManager?) {
        self.manager = manager
        status = manager?.connection.status ?? .invalid
        savedEndpoint = manager.flatMap {
            Self.legacyRevision(of: $0) == nil ? nil : $0.protocolConfiguration?.serverAddress
        }
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
