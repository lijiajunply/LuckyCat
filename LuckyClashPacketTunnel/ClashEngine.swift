import Clash
import Darwin
import Foundation
import Network
import NetworkExtension
import os

/// Runs the pinned Clash core with a packet bridge owned by the tunnel
/// extension. The core performs DNS, rule matching and outbound dialing; this
/// type only translates NEPacketTunnelFlow into the core's descriptor bridge
/// and provides the platform callbacks the core expects.
final class ClashEngine: NSObject, @unchecked Sendable {
    enum Failure: LocalizedError {
        case configuration
        case core(String)
        case networkSettings
        case bridge(String)

        var errorDescription: String? {
            switch self {
            case .configuration: "Clash 配置不可用，请重新导入。"
            case .core(let message): message
            case .networkSettings: "iOS 无法应用隧道网络设置。"
            case .bridge(let message): message
            }
        }
    }

    private static let log = Logger(
        subsystem: "com.luckyfish.LuckyCat.PacketTunnel", category: "clash"
    )
    private static let availableFlag: UInt32 = 1 << 8
    private static let defaultFlag: UInt32 = 1 << 9
    private static let ownTunnelFlag: UInt32 = 1 << 10

    private let provider: NEPacketTunnelProvider
    private let lifecycle = DispatchQueue(label: "com.luckyfish.LuckyCat.clash.lifecycle")
    private let pathQueue = DispatchQueue(label: "com.luckyfish.LuckyCat.clash.path")
    private let pathLock = NSLock()
    private let stateLock = NSLock()

    private var service: ClashBoxService?
    private var bridge: PacketFlowBridge?
    private var pathMonitor: NWPathMonitor?
    private var interfaceListener: (any ClashInterfaceUpdateListenerProtocol)?
    private var defaultInterfaceIndex: UInt32 = 0
    private var defaultInterfaceName = ""
    private var pathExpensive = false
    private var pathConstrained = false
    private var pathSupportsIPv4 = false
    private var pathSupportsIPv6 = false
    private var firstPathArrived = false
    private let firstPath = DispatchSemaphore(value: 0)

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    func start(
        configurationText: String,
        selectedGroup: String?,
        selectedNode: String?,
        completion: @escaping (Error?) -> Void
    ) {
        lifecycle.async { [self] in
            do {
                startPathMonitor()
                try prepareCore()
                let service = try makeService()
                self.service = service

                let outcome = service.startClassified(configurationText)
                let errorClass = outcome?.errorClass ?? "unknown"
                if !errorClass.isEmpty, errorClass != ClashCoreOutcomeCommitted {
                    let message = outcome?.message ?? "Clash 内核拒绝配置。"
                    throw Failure.core(message)
                }
                if let selectedGroup, let selectedNode, !selectedGroup.isEmpty, !selectedNode.isEmpty {
                    var selectError: NSError?
                    if !ClashSelectProxy(selectedGroup, selectedNode, &selectError) {
                        Self.log.notice("proxy selection was not applied: \(selectError?.localizedDescription ?? "unknown", privacy: .public)")
                    }
                }
                Self.log.notice("clash core started: \(ClashVersion(), privacy: .public)")
                completion(nil)
            } catch {
                Self.log.error("clash start failed: \(error.localizedDescription, privacy: .public)")
                stopLocked()
                completion(error)
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        lifecycle.async { [self] in
            stopLocked()
            completion?()
        }
    }

    func traffic() -> (received: UInt64, sent: UInt64)? {
        guard let data = ClashTrafficJSON().data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (values["downTotal"] as? NSNumber)?.uint64Value,
              let up = (values["upTotal"] as? NSNumber)?.uint64Value else {
            return nil
        }
        return (down, up)
    }

    func isReady() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return service != nil
    }

    // MARK: - Core setup

    private func stopLocked() {
        stateLock.lock()
        bridge?.stop()
        bridge = nil
        let current = service
        service = nil
        stateLock.unlock()
        try? current?.close()
        pathMonitor?.cancel()
        pathMonitor = nil
        pathLock.lock()
        interfaceListener = nil
        pathLock.unlock()
    }

    private func prepareCore() throws {
        // The core binds a Unix socket at basePath/clash.sock, and Darwin
        // rejects paths longer than 103 bytes. Keep this at the container root
        // instead of adding a product subdirectory.
        let container = try sharedContainer()
        let options = ClashSetupOptions()
        options.basePath = container.path
        options.workingPath = container.appending(path: "working").path
        options.tempPath = container.appending(path: "temp").path
        options.startupPhaseLogPath = container.appending(path: "startup-phases.log").path
        options.timeZone = TimeZone.current.identifier
        options.runtimeProfile = ClashRuntimeProfileIOSPacketTunnel
        options.logMaxLines = 500
        options.systemDNSServerLines = ClashSystemResolverLines()
        options.includeAllNetworks = (provider.protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks ?? false
        options.disablePersistentCache = false
        options.persistentCacheDirectory = URL.applicationSupportDirectory.path

        var error: NSError?
        if !ClashSetup(options, &error) {
            throw error ?? Failure.core("Clash 内核初始化失败。")
        }
    }

    private func makeService() throws -> ClashBoxService {
        var error: NSError?
        guard let service = ClashNewService(Platform(engine: self), &error) else {
            throw error ?? Failure.core("无法创建 Clash 内核。")
        }
        return service
    }

    private func sharedContainer() throws -> URL {
        #if targetEnvironment(simulator)
        let root = URL.applicationSupportDirectory
        #else
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.luckyfish.LuckyCat"
        ) else {
            throw PrototypeError.sharedContainerUnavailable
        }
        #endif
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Physical interface

    private func startPathMonitor() {
        if pathMonitor != nil { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.pathQueue.async { self.handle(path) }
        }
        pathMonitor = monitor
        monitor.start(queue: pathQueue)
        _ = firstPath.wait(timeout: .now() + 3)
    }

    /// Called on `pathQueue`.
    private func handle(_ path: Network.NWPath) {
        // Once the tunnel is up, NWPathMonitor can report our own utun as an
        // available interface. Never bind the core's outbound sockets to it.
        let interface = path.availableInterfaces.first { !$0.name.hasPrefix("utun") }

        pathLock.lock()
        if let interface, !interface.name.isEmpty {
            defaultInterfaceName = interface.name
            defaultInterfaceIndex = if_nametoindex(interface.name)
        }
        let name = defaultInterfaceName
        let index = defaultInterfaceIndex
        let satisfied = path.status == .satisfied && index != 0
        pathExpensive = path.isExpensive
        pathConstrained = path.isConstrained
        pathSupportsIPv4 = path.supportsIPv4
        pathSupportsIPv6 = path.supportsIPv6
        let listener = interfaceListener
        let signal = satisfied && !firstPathArrived
        if signal { firstPathArrived = true }
        pathLock.unlock()

        listener?.updateDefaultInterface(
            name, interfaceIndex: Int32(bitPattern: index),
            isExpensive: path.isExpensive, isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6
        )
        if signal { firstPath.signal() }
    }

    fileprivate func bind(_ descriptor: Int32) throws {
        pathLock.lock()
        let index = defaultInterfaceIndex
        pathLock.unlock()
        guard index != 0 else {
            throw Failure.core("无法确定默认网络接口，请检查网络后重试。")
        }
        var value = index
        let size = socklen_t(MemoryLayout<UInt32>.size)
        if setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &value, size) != 0 {
            let code = errno
            if code != EINVAL, code != ENOPROTOOPT {
                Self.log.warning("IP_BOUND_IF failed: \(code, privacy: .public)")
            }
        }
        if setsockopt(descriptor, IPPROTO_IPV6, IPV6_BOUND_IF, &value, size) != 0 {
            let code = errno
            if code != EINVAL, code != ENOPROTOOPT {
                Self.log.warning("IPV6_BOUND_IF failed: \(code, privacy: .public)")
            }
        }
    }

    fileprivate func startInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        pathLock.lock()
        interfaceListener = listener
        let index = defaultInterfaceIndex
        let name = defaultInterfaceName
        let expensive = pathExpensive
        let constrained = pathConstrained
        let supportsIPv4 = pathSupportsIPv4
        let supportsIPv6 = pathSupportsIPv6
        pathLock.unlock()

        listener?.updateDefaultInterface(
            name, interfaceIndex: Int32(bitPattern: index),
            isExpensive: expensive, isConstrained: constrained,
            supportsIPv4: supportsIPv4, supportsIPv6: supportsIPv6
        )
    }

    fileprivate func closeInterfaceMonitor(_: (any ClashInterfaceUpdateListenerProtocol)?) {
        pathLock.lock()
        interfaceListener = nil
        pathLock.unlock()
    }

    fileprivate func interfaces() -> any ClashNetworkInterfaceIteratorProtocol {
        pathLock.lock()
        let defaultName = defaultInterfaceName
        pathLock.unlock()
        return InterfaceIterator(entries: Self.enumerateInterfaces(defaultName: defaultName))
    }

    private static func enumerateInterfaces(defaultName: String) -> [ClashNetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        struct Entry {
            var index: UInt32 = 0
            var flags: UInt32 = 0
            var addresses: [String] = []
        }
        var grouped: [String: Entry] = [:]
        var order: [String] = []

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            let name = String(cString: item.ifa_name)
            if grouped[name] == nil {
                grouped[name] = Entry()
                order.append(name)
            }
            grouped[name]!.index = if_nametoindex(name)
            grouped[name]!.flags = item.ifa_flags
            guard let address = item.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 {
                grouped[name]!.addresses.append(String(cString: host))
            }
        }

        return order.compactMap { name in
            guard let entry = grouped[name], entry.index != 0 else { return nil }
            let interface = ClashNetworkInterface()
            interface.index = Int32(entry.index)
            interface.name = name
            interface.addresses = StringIterator(values: entry.addresses)
            interface.mtu = 0
            interface.metered = false
            interface.type = Self.interfaceType(name: name)
            var flags = entry.flags & 0xFF
            if entry.flags & UInt32(IFF_UP) != 0, entry.flags & UInt32(IFF_RUNNING) != 0 {
                flags |= Self.availableFlag
            }
            if name == defaultName { flags |= Self.defaultFlag }
            if name.hasPrefix("utun") { flags |= Self.ownTunnelFlag }
            interface.flags = Int32(bitPattern: flags)
            return interface
        }
    }

    private static func interfaceType(name: String) -> Int32 {
        if name.hasPrefix("pdp_ip") { return 2 } // cellular
        if name.hasPrefix("en") { return 1 }     // wifi
        return 0
    }

    // MARK: - Tunnel settings

    fileprivate func openTun(
        _ options: (any ClashTunOptionsProtocol)?,
        ret0_: UnsafeMutablePointer<Int32>?
    ) throws {
        guard let options, let ret0_ else {
            throw Failure.networkSettings
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        let dns = try options.getDNSServerAddress()
        guard !dns.value.isEmpty else { throw Failure.networkSettings }
        let dnsSettings = NEDNSSettings(servers: [dns.value])
        dnsSettings.matchDomains = [""]
        dnsSettings.matchDomainsNoSearch = true
        settings.dnsSettings = dnsSettings

        let v4 = collect(options.getInet4Address())
        if !v4.isEmpty {
            let ipv4 = NEIPv4Settings(
                addresses: v4.map(\.address), subnetMasks: v4.map(\.mask)
            )
            let included = collect(options.getInet4RouteAddress())
            ipv4.includedRoutes = included.isEmpty
                ? [.default()]
                : included.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask) }
            ipv4.excludedRoutes = collect(options.getInet4RouteExcludeAddress()).map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask)
            }
            settings.ipv4Settings = ipv4
        }

        let v6 = collect(options.getInet6Address())
        if !v6.isEmpty {
            let ipv6 = NEIPv6Settings(
                addresses: v6.map(\.address), networkPrefixLengths: v6.map { NSNumber(value: $0.prefix) }
            )
            let included = collect(options.getInet6RouteAddress())
            ipv6.includedRoutes = included.isEmpty
                ? [.default()]
                : included.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) }
            ipv6.excludedRoutes = collect(options.getInet6RouteExcludeAddress()).map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix))
            }
            settings.ipv6Settings = ipv6
        }

        let semaphore = DispatchSemaphore(value: 0)
        var applyError: Error?
        provider.setTunnelNetworkSettings(settings) { error in
            applyError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            throw Failure.networkSettings
        }
        if let applyError { throw applyError }

        let bridge = PacketFlowBridge(
            packetFlow: provider.packetFlow,
            logLine: { Self.log.debug("\($0, privacy: .public)") },
            onFailure: { [weak self] error in
                Self.log.error("packet bridge failed: \(error.localizedDescription, privacy: .public)")
                self?.provider.cancelTunnelWithError(error)
            }
        )
        let descriptor = try bridge.start()
        stateLock.lock()
        self.bridge = bridge
        stateLock.unlock()
        ret0_.pointee = descriptor
    }

    private func collect(_ iterator: (any ClashRoutePrefixIteratorProtocol)?) -> [(address: String, mask: String, prefix: Int32)] {
        guard let iterator else { return [] }
        var values: [(String, String, Int32)] = []
        while iterator.hasNext() {
            guard let prefix = iterator.next() else { break }
            values.append((prefix.address(), prefix.mask(), prefix.prefix()))
        }
        return values
    }
}

// MARK: - Core platform callbacks

private final class Platform: NSObject, ClashPlatformInterfaceProtocol {
    private weak var engine: ClashEngine?

    init(engine: ClashEngine) {
        self.engine = engine
    }

    func writeLog(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        ClashEngine.logForEngine.debug("\(message, privacy: .public)")
    }

    func tunFailed(_ reason: String?) {
        guard let reason else { return }
        ClashEngine.logForEngine.error("tun failed: \(reason, privacy: .public)")
        engine?.cancel(reason: reason)
    }

    func openTun(_ options: (any ClashTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let engine else { throw ClashEngine.Failure.networkSettings }
        try engine.openTun(options, ret0_: ret0_)
    }

    func usePlatformAutoDetectControl() -> Bool { true }

    func autoDetectControl(_ fd: Int32) throws {
        guard let engine else { return }
        try engine.bind(fd)
    }

    func startDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        try engine?.startInterfaceMonitor(listener)
    }

    func closeDefaultInterfaceMonitor(_ listener: (any ClashInterfaceUpdateListenerProtocol)?) throws {
        engine?.closeInterfaceMonitor(listener)
    }

    func getInterfaces() throws -> any ClashNetworkInterfaceIteratorProtocol {
        engine?.interfaces() ?? InterfaceIterator(entries: [])
    }

    func underNetworkExtension() -> Bool { true }
}

private final class InterfaceIterator: NSObject, ClashNetworkInterfaceIteratorProtocol {
    private let entries: [ClashNetworkInterface]
    private var index = 0

    init(entries: [ClashNetworkInterface]) {
        self.entries = entries
    }

    func hasNext() -> Bool { index < entries.count }
    func len() -> Int32 { Int32(entries.count - index) }
    func next() -> ClashNetworkInterface? {
        guard index < entries.count else { return nil }
        defer { index += 1 }
        return entries[index]
    }
}

private final class StringIterator: NSObject, ClashStringIteratorProtocol {
    private let values: [String]
    private var index = 0

    init(values: [String]) {
        self.values = values
    }

    func hasNext() -> Bool { index < values.count }
    func len() -> Int32 { Int32(values.count - index) }
    func next() -> String {
        guard index < values.count else { return "" }
        defer { index += 1 }
        return values[index]
    }
}

extension ClashEngine {
    fileprivate static let logForEngine = log

    fileprivate func cancel(reason: String) {
        provider.cancelTunnelWithError(Failure.core(reason))
    }
}
