import Foundation
import NetworkExtension
import Observation

@Observable
final class PrototypeVPN {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var busy = false
    private(set) var requestingConnection = false
    private(set) var imported: PrototypeConfiguration?
    private(set) var savedEndpoint: String?
    var message: String?

    private var manager: NETunnelProviderManager?
    private var connectionRequest: UUID?
    private var statusChangedAt = UUID()

    var isActive: Bool {
        requestingConnection || [.connecting, .connected, .reasserting, .disconnecting].contains(status)
    }

    var canStop: Bool {
        isActive && status != .disconnecting
    }

    func importFile(_ url: URL) {
        guard !busy, !isActive else { return }
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: PrototypeConfiguration.maximumFileSize + 1) ?? Data()
            imported = try PrototypeConfiguration.decode(data)
            message = nil
        } catch let error as PrototypeError.InvalidField {
            message = error.localizedDescription
        } catch {
            message = "无法读取测试配置文件。"
        }
    }

    func refresh() async {
        #if !targetEnvironment(simulator)
        guard !busy, !requestingConnection else { return }
        busy = true
        defer { busy = false }
        do {
            adopt(try await loadManager())
        } catch {
            message = Self.describe(error)
        }
        #endif
    }

    func connect() async {
        #if targetEnvironment(simulator)
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
            if let imported {
                selected = try await save(imported, to: existing ?? NETunnelProviderManager())
                self.imported = nil
            } else if let existing {
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
            guard try Self.revision(of: selected).map({ try PrototypeStore.load(revision: $0) }) != nil else {
                throw PrototypeError.missingConfiguration
            }
            guard let session = selected.connection as? NETunnelProviderSession else {
                throw PrototypeError.missingConfiguration
            }

            let request = UUID()
            connectionRequest = request
            requestingConnection = true
            do {
                try session.startTunnel(options: nil)
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
        clearConnectionRequest()
        message = nil
        manager?.connection.stopVPNTunnel()
    }

    func updateStatus() async {
        guard let connection = manager?.connection else { return }
        let previous = status
        let current = connection.status
        if current != previous {
            statusChangedAt = UUID()
            status = current
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
        _ configuration: PrototypeConfiguration,
        to manager: NETunnelProviderManager
    ) async throws -> NETunnelProviderManager {
        let previousRevision = Self.revision(of: manager)
        let revision = UUID()
        let provider = NETunnelProviderProtocol()
        provider.providerBundleIdentifier = try Self.providerIdentifier()
        provider.serverAddress = configuration.endpoint
        provider.providerConfiguration = [
            PrototypeStore.configurationIdentifierKey: PrototypeStore.configurationIdentifier,
            PrototypeStore.revisionKey: revision.uuidString
        ]

        try PrototypeStore.save(configuration, revision: revision)
        manager.protocolConfiguration = provider
        manager.localizedDescription = "LuckyCat · WireGuard"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        do {
            try await manager.saveToPreferences()
        } catch {
            PrototypeStore.remove(revision: revision)
            throw error
        }
        try await manager.loadFromPreferences()
        if let previousRevision, [.invalid, .disconnected].contains(manager.connection.status) {
            PrototypeStore.remove(revision: previousRevision)
        }
        return manager
    }

    private func adopt(_ manager: NETunnelProviderManager?) {
        self.manager = manager
        status = manager?.connection.status ?? .invalid
        savedEndpoint = manager?.protocolConfiguration?.serverAddress
    }

    private func clearConnectionRequest() {
        requestingConnection = false
        connectionRequest = nil
    }

    private static func revision(of manager: NETunnelProviderManager) -> UUID? {
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
        if nsError.domain == NEVPNErrorDomain && nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
            return "无法读写系统 VPN 配置，请核对 VPN 授权和签名。"
        }
        return "VPN 操作失败（\(nsError.domain) \(nsError.code)）。"
    }
}
