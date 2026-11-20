import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let lifecycle = DispatchQueue(label: "com.luckyfish.LuckyCat.PacketTunnel")
    private var engine: UInt = 0
    private var generation = UUID()
    private var startupCompletion: ((Error?) -> Void)?
    private var handshakeTimer: DispatchSourceTimer?
    private var ready = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lifecycle.async {
            guard self.startupCompletion == nil, self.engine == 0, !self.ready else {
                completionHandler(PrototypeError.engineStartup)
                return
            }
            self.startupCompletion = completionHandler
            let generation = UUID()
            self.generation = generation
            do {
                let (configuration, plan) = try self.loadConfiguration()
                let routePlan = plan ?? .global
                if routePlan.mode == .direct {
                    self.applySettings(
                        configuration, plan: routePlan, generation: generation,
                        deadline: DispatchTime.now() + .seconds(5)
                    )
                } else {
                    self.beginHandshake(configuration, plan: routePlan, generation: generation)
                }
            } catch {
                self.finishStartup(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycle.async {
            self.generation = UUID()
            self.ready = false
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
            var received: UInt64 = 0
            var sent: UInt64 = 0
            let hasTraffic = self.engine != 0
                && LCWireGuardTraffic(self.engine, &received, &sent) != 0
            let reply = TunnelStatusMessage.Reply(
                version: TunnelStatusMessage.version,
                id: request.id,
                ready: self.ready && self.startupCompletion == nil,
                bytesIn: hasTraffic ? received : nil,
                bytesOut: hasTraffic ? sent : nil
            )
            completionHandler?(try? JSONEncoder().encode(reply))
        }
    }

    private func loadConfiguration() throws -> (configuration: PrototypeConfiguration, routePlan: RoutePlan?) {
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
            return try TunnelSnapshot.loadTunnel(profileID: profile, revision: revision)
        }
        guard let rawRevision = values[PrototypeStore.revisionKey] as? String,
              let revision = UUID(uuidString: rawRevision) else {
            throw PrototypeError.missingConfiguration
        }
        return (try PrototypeStore.load(revision: revision), nil)
    }

    private func beginHandshake(_ configuration: PrototypeConfiguration, plan: RoutePlan, generation: UUID) {
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
                self.applySettings(configuration, plan: plan, generation: generation, deadline: deadline)
            } else if DispatchTime.now() >= deadline {
                self.finishStartup(PrototypeError.handshakeTimeout)
            }
        }
        handshakeTimer = timer
        timer.activate()
    }

    private func applySettings(
        _ configuration: PrototypeConfiguration, plan: RoutePlan, generation: UUID, deadline: DispatchTime
    ) {
        lifecycle.asyncAfter(deadline: max(deadline, .now() + .seconds(5))) { [weak self] in
            guard let self, self.generation == generation, self.startupCompletion != nil else { return }
            self.finishStartup(PrototypeError.networkSettings)
        }
        setTunnelNetworkSettings(Self.networkSettings(for: configuration, plan: plan)) { [weak self] error in
            guard let self else { return }
            self.lifecycle.async {
                guard self.generation == generation else { return }
                if error != nil {
                    self.finishStartup(PrototypeError.networkSettings)
                } else {
                    self.ready = true
                    if plan.mode != .direct {
                        self.readPackets(generation: generation)
                    }
                    self.finishStartup(nil)
                }
            }
        }
    }

    private func finishStartup(_ error: Error?) {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        if error != nil {
            ready = false
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

    private static func networkSettings(
        for configuration: PrototypeConfiguration, plan: RoutePlan
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: configuration.endpointAddress)
        settings.mtu = NSNumber(value: PrototypeConfiguration.mtu)

        let ipv4 = NEIPv4Settings(addresses: [configuration.clientIPv4], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = plan.ipv4Included.compactMap { ipv4Route($0) }
        var ipv4Excluded = plan.ipv4Excluded.compactMap { ipv4Route($0) }
        if IPv4Address(configuration.endpointAddress) != nil {
            ipv4Excluded.append(NEIPv4Route(
                destinationAddress: configuration.endpointAddress, subnetMask: "255.255.255.255"
            ))
        }
        ipv4.excludedRoutes = ipv4Excluded
        settings.ipv4Settings = ipv4

        // Use a /120 interface prefix for iOS. The peer still authorizes the client as a /128.
        let ipv6 = NEIPv6Settings(addresses: [configuration.clientIPv6], networkPrefixLengths: [120])
        ipv6.includedRoutes = plan.ipv6Included.compactMap { ipv6Route($0) }
        var ipv6Excluded = plan.ipv6Excluded.compactMap { ipv6Route($0) }
        if IPv6Address(configuration.endpointAddress) != nil {
            ipv6Excluded.append(NEIPv6Route(
                destinationAddress: configuration.endpointAddress, networkPrefixLength: 128
            ))
        }
        ipv6.excludedRoutes = ipv6Excluded
        settings.ipv6Settings = ipv6

        if plan.usesTunnelDNS {
            let dns = NEDNSSettings(servers: configuration.dnsServers)
            dns.matchDomains = [""]
            dns.matchDomainsNoSearch = true
            settings.dnsSettings = dns
        }
        return settings
    }

    private static func ipv4Route(_ prefix: IPPrefix) -> NEIPv4Route? {
        guard IPv4Address(prefix.address) != nil, (0...32).contains(prefix.prefixLength) else { return nil }
        if prefix.prefixLength == 0 { return .default() }
        let mask: UInt32 = UInt32.max << (32 - prefix.prefixLength)
        let subnetMask = "\(mask >> 24 & 255).\(mask >> 16 & 255).\(mask >> 8 & 255).\(mask & 255)"
        return NEIPv4Route(destinationAddress: prefix.address, subnetMask: subnetMask)
    }

    private static func ipv6Route(_ prefix: IPPrefix) -> NEIPv6Route? {
        guard IPv6Address(prefix.address) != nil, (0...128).contains(prefix.prefixLength) else { return nil }
        if prefix.prefixLength == 0 { return .default() }
        return NEIPv6Route(
            destinationAddress: prefix.address, networkPrefixLength: NSNumber(value: prefix.prefixLength)
        )
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
