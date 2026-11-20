import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let lifecycle = DispatchQueue(label: "com.luckyfish.LuckyCat.PacketTunnel")
    private var engine: UInt = 0
    private var generation = UUID()
    private var startupCompletion: ((Error?) -> Void)?
    private var handshakeTimer: DispatchSourceTimer?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lifecycle.async {
            guard self.startupCompletion == nil, self.engine == 0 else {
                completionHandler(PrototypeError.engineStartup)
                return
            }
            self.startupCompletion = completionHandler
            let generation = UUID()
            self.generation = generation
            do {
                let configuration = try self.loadConfiguration()
                self.beginHandshake(configuration, generation: generation)
            } catch {
                self.finishStartup(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycle.async {
            self.generation = UUID()
            self.finishStartup(PrototypeError.startCancelled)
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard messageData.count <= 256,
              let request = try? JSONDecoder().decode(TunnelStatusMessage.Request.self, from: messageData),
              request.version == TunnelStatusMessage.version else {
            completionHandler?(nil)
            return
        }
        lifecycle.async {
            let reply = TunnelStatusMessage.Reply(
                version: TunnelStatusMessage.version,
                id: request.id,
                ready: self.engine != 0 && self.startupCompletion == nil
            )
            completionHandler?(try? JSONEncoder().encode(reply))
        }
    }

    private func loadConfiguration() throws -> PrototypeConfiguration {
        guard let provider = protocolConfiguration as? NETunnelProviderProtocol,
              let values = provider.providerConfiguration,
              values[PrototypeStore.configurationIdentifierKey] as? String == PrototypeStore.configurationIdentifier else {
            throw PrototypeError.missingConfiguration
        }
        if values[TunnelSnapshot.profileKey] != nil || values[TunnelSnapshot.revisionKey] != nil {
            guard let profile = (values[TunnelSnapshot.profileKey] as? String).flatMap(UUID.init(uuidString:)),
                  let revision = (values[TunnelSnapshot.revisionKey] as? String).flatMap(UUID.init(uuidString:)) else {
                throw PrototypeError.missingConfiguration
            }
            return try TunnelSnapshot.load(profileID: profile, revision: revision)
        }
        guard let rawRevision = values[PrototypeStore.revisionKey] as? String,
              let revision = UUID(uuidString: rawRevision) else {
            throw PrototypeError.missingConfiguration
        }
        return try PrototypeStore.load(revision: revision)
    }

    private func beginHandshake(_ configuration: PrototypeConfiguration, generation: UUID) {
        do {
            var settings = try configuration.wireGuardSettings().utf8CString
            // The provider owns packetFlow until LCWireGuardStop joins the writer.
            let context = UInt(bitPattern: Unmanaged.passUnretained(packetFlow).toOpaque())
            engine = settings.withUnsafeMutableBufferPointer {
                LCWireGuardStart($0.baseAddress, Int32(PrototypeConfiguration.mtu), context, writePacket)
            }
            guard engine != 0 else { throw PrototypeError.engineStartup }
        } catch {
            finishStartup(error)
            return
        }

        let deadline = DispatchTime.now() + .seconds(15)
        let timer = DispatchSource.makeTimerSource(queue: lifecycle)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == generation else { return }
            if LCWireGuardHasHandshake(self.engine) != 0 {
                self.handshakeTimer?.cancel()
                self.handshakeTimer = nil
                self.applySettings(configuration, generation: generation, deadline: deadline)
            } else if DispatchTime.now() >= deadline {
                self.finishStartup(PrototypeError.handshakeTimeout)
            }
        }
        handshakeTimer = timer
        timer.activate()
    }

    private func applySettings(_ configuration: PrototypeConfiguration, generation: UUID, deadline: DispatchTime) {
        lifecycle.asyncAfter(deadline: max(deadline, .now() + .seconds(5))) { [weak self] in
            guard let self, self.generation == generation, self.startupCompletion != nil else { return }
            self.finishStartup(PrototypeError.networkSettings)
        }
        setTunnelNetworkSettings(Self.networkSettings(for: configuration)) { [weak self] error in
            guard let self else { return }
            self.lifecycle.async {
                guard self.generation == generation else { return }
                if error != nil {
                    self.finishStartup(PrototypeError.networkSettings)
                } else {
                    self.readPackets(generation: generation)
                    self.finishStartup(nil)
                }
            }
        }
    }

    private func finishStartup(_ error: Error?) {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        if error != nil {
            generation = UUID()
            if engine != 0 {
                LCWireGuardStop(engine)
                engine = 0
            }
        }
        let completion = startupCompletion
        startupCompletion = nil
        completion?(error)
    }

    private func readPackets(generation: UUID) {
        packetFlow.readPacketObjects { [weak self] packets in
            guard let self else { return }
            self.lifecycle.async {
                guard self.generation == generation, self.engine != 0 else { return }
                for packet in packets where packet.protocolFamily == sa_family_t(AF_INET)
                    || packet.protocolFamily == sa_family_t(AF_INET6) {
                    packet.data.withUnsafeBytes { buffer in
                        guard let address = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                        _ = LCWireGuardEnqueue(self.engine, UnsafeMutablePointer(mutating: address), Int32(buffer.count))
                    }
                }
                self.readPackets(generation: generation)
            }
        }
    }

    private static func networkSettings(for configuration: PrototypeConfiguration) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.endpointAddress)
        settings.mtu = NSNumber(value: PrototypeConfiguration.mtu)

        let ipv4 = NEIPv4Settings(addresses: [configuration.clientIPv4], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [.default()]
        if IPv4Address(configuration.endpointAddress) != nil {
            ipv4.excludedRoutes = [
                NEIPv4Route(destinationAddress: configuration.endpointAddress, subnetMask: "255.255.255.255")
            ]
        }
        settings.ipv4Settings = ipv4

        // Use a /120 interface prefix for iOS. The peer still authorizes the client as a /128.
        let ipv6 = NEIPv6Settings(addresses: [configuration.clientIPv6], networkPrefixLengths: [120])
        ipv6.includedRoutes = [.default()]
        if IPv6Address(configuration.endpointAddress) != nil {
            ipv6.excludedRoutes = [
                NEIPv6Route(destinationAddress: configuration.endpointAddress, networkPrefixLength: 128)
            ]
        }
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: configuration.dnsServers)
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        return settings
    }
}

private let writePacket: LCWireGuardWriter = { context, bytes, length in
    guard let bytes, length > 0, let pointer = UnsafeRawPointer(bitPattern: context) else { return }
    let family: sa_family_t
    switch bytes.pointee >> 4 {
    case 4: family = sa_family_t(AF_INET)
    case 6: family = sa_family_t(AF_INET6)
    default: return
    }
    let flow = Unmanaged<NEPacketTunnelFlow>.fromOpaque(pointer).takeUnretainedValue()
    let packet = NEPacket(data: Data(bytes: bytes, count: Int(length)), protocolFamily: family)
    _ = flow.writePacketObjects([packet])
}
