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
        subsystem: "com.luckyfish.LuckyClash.PacketTunnel", category: "clash"
    )
    private static let availableFlag: UInt32 = 1 << 8
    private static let defaultFlag: UInt32 = 1 << 9
    private static let ownTunnelFlag: UInt32 = 1 << 10
    // The SDK sets Go's soft limit to 75% of this budget. Leave room for
    // Swift, NetworkExtension and the packet bridge outside the Go heap.
    private static let memoryBudget: Int64 = 48 * 1024 * 1024

    private let provider: NEPacketTunnelProvider
    private let lifecycle = DispatchQueue(label: "com.luckyfish.LuckyClash.clash.lifecycle")
    private let pathQueue = DispatchQueue(label: "com.luckyfish.LuckyClash.clash.path")
    private let pathLock = NSLock()
    private let stateLock = NSLock()

    private var service: ClashBoxService?
    private var bridge: PacketFlowBridge?
    private var pathMonitor: NWPathMonitor?
    private var memoryPressureMonitor: DispatchSourceMemoryPressure?
    private var interfaceListener: (any ClashInterfaceUpdateListenerProtocol)?
    private var networkKind = ""
    private var routers = ""
    private var routeRecovery: DispatchWorkItem?
    private var socketPath: String?
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
        groupSelections: [String: String],
        selectedNode: String?,
        mode: TrafficMode?,
        completion: @escaping (Error?) -> Void
    ) {
        lifecycle.async { [self] in
            do {
                startPathMonitor()
                try prepareCore()
                let service = try makeService()
                stateLock.withLock { self.service = service }

                let outcome = service.startClassified(configurationText)
                let errorClass = outcome?.errorClass ?? "unknown"
                if !errorClass.isEmpty, errorClass != ClashCoreOutcomeCommitted {
                    let message = outcome?.message ?? "Clash 内核拒绝配置。"
                    throw Failure.core(message)
                }
                try applySelection(groupSelections, globalNode: selectedNode, mode: mode)
                Self.log.notice("clash core started: \(ClashVersion(), privacy: .public)")
                completion(nil)
            } catch {
                Self.log.error("clash start failed: \(error.localizedDescription, privacy: .public)")
                recordStartupExplanation(previous: false)
                stopLocked()
                completion(error)
            }
        }
    }

    func reload(
        _ request: TunnelReloadMessage.Request,
        completion: @escaping (TunnelReloadMessage.Reply) -> Void
    ) {
        lifecycle.async { [self] in
            func finish(_ outcome: TunnelReloadMessage.Outcome, _ message: String? = nil) {
                completion(.init(version: TunnelReloadMessage.version, id: request.id, outcome: outcome, message: message))
            }
            guard let service else {
                finish(.restart)
                return
            }
            let selection = request.selection
            guard selection.mode != .global || !(selection.node ?? "").isEmpty else {
                finish(.rejected, "全局模式需要选择一个代理节点。")
                return
            }
            guard let configuration = try? selection.configuration() else {
                finish(.rejected, "无法读取待应用的配置。")
                return
            }
            let result = service.reloadClassified(configuration)
            switch result?.errorClass {
            case "", ClashCoreOutcomeCommitted:
                do {
                    try applySelection(selection.groupSelections, globalNode: selection.node, mode: selection.mode)
                    finish(.applied)
                } catch {
                    finish(.restart)
                }
            case ClashCoreOutcomeConfig:
                finish(.rejected, "内核拒绝新配置，当前连接继续使用原配置。")
            default:
                finish(.restart)
            }
        }
    }

    private func applySelection(_ groupSelections: [String: String], globalNode: String?, mode: TrafficMode?) throws {
        // The core's optional YAML store-selected cache is shared by group
        // name. Restore defaults for groups that this profile has never set.
        if let socketPath, let client = ClashNewAPIClient(socketPath, APIControlHandler(), nil) {
            defer { client.close() }
            var error: NSError?
            let groups = client.getGroups(&error)
            if let entries = Self.evidenceFields(groups)?["proxies"] as? [[String: Any]] {
                for entry in entries {
                    guard let name = entry["name"] as? String, name != "GLOBAL",
                          groupSelections[name] == nil,
                          let type = (entry["type"] as? String)?.lowercased() else { continue }
                    switch type {
                    case "selector", "select":
                        if let first = (entry["all"] as? [String])?.first {
                            _ = ClashSelectProxy(name, first, nil)
                        }
                    case "urltest", "url-test", "fallback":
                        if let fixed = entry["fixed"] as? String, !fixed.isEmpty {
                            _ = ClashUnfixProxy(name, nil)
                        }
                    default:
                        break
                    }
                }
            }
        }
        for (group, node) in groupSelections.sorted(by: { $0.key < $1.key }) where group != "GLOBAL" {
            if !ClashSelectProxy(group, node, nil) {
                Self.log.notice("saved proxy selection was not applied")
            }
        }
        guard mode == .global else { return }
        guard let node = globalNode, !node.isEmpty else {
            throw Failure.core("全局模式需要选择一个代理节点。")
        }
        if !ClashSelectProxy("GLOBAL", node, nil) {
            throw Failure.core("无法设置全局代理节点。")
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        lifecycle.async { [self] in
            stopLocked()
            completion?()
        }
    }

    func freeMemory(completion: @escaping () -> Void) {
        lifecycle.async {
            ClashFreeMemory()
            completion()
        }
    }

    func sleep(completion: @escaping () -> Void) {
        lifecycle.async { [self] in
            service?.pause()
            completion()
        }
    }

    func wake() {
        lifecycle.async { [self] in
            service?.wake()
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
        memoryPressureMonitor?.cancel()
        memoryPressureMonitor = nil
        stateLock.lock()
        bridge?.stop()
        bridge = nil
        let current = service
        service = nil
        stateLock.unlock()
        try? current?.close()
        pathMonitor?.cancel()
        pathMonitor = nil
        pathQueue.sync {
            routeRecovery?.cancel()
            routeRecovery = nil
        }
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
        options.memoryLimit = Self.memoryBudget
        options.memoryPressureShed = true
        options.logMaxLines = 500
        options.systemDNSServerLines = ClashSystemResolverLines()
        let tunnelProtocol = provider.protocolConfiguration as? NETunnelProviderProtocol
        let settings = tunnelProtocol?.providerConfiguration
        options.includeAllNetworks = tunnelProtocol?.includeAllNetworks ?? false
        options.tunIPv6Mode = settings?[TunnelNetworkOptions.ipv6Mode] as? String ?? "config"
        options.ipQueryMode = settings?[TunnelNetworkOptions.queryMode] as? String ?? "config"
        options.tunMTU = settings?[TunnelNetworkOptions.mtu] as? Int ?? 0
        options.disablePersistentCache = false
        options.persistentCacheDirectory = URL.applicationSupportDirectory.path

        var error: NSError?
        if !ClashSetup(options, &error) {
            throw error ?? Failure.core("Clash 内核初始化失败。")
        }
        socketPath = container.appending(path: "clash.sock").path
        collectPreviousEvidence()
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: lifecycle)
        monitor.setEventHandler {
            if ClashRecordMemoryPressureEvidence(nil) {
                TunnelDiagnosticEvents.append("PacketTunnel 收到严重内存压力")
            } else {
                TunnelDiagnosticEvents.append("PacketTunnel 内存压力取证写入失败")
            }
        }
        memoryPressureMonitor = monitor
        monitor.activate()
    }

    private func collectPreviousEvidence() {
        if let evidence = ClashConsumeOOMEvidence(nil),
           let fields = Self.evidenceFields(evidence.value) {
            let heap = (fields["heapInuseBytes"] as? NSNumber)?.int64Value ?? 0
            let stack = (fields["stackInuseBytes"] as? NSNumber)?.int64Value ?? 0
            let reloadPhase = fields["reloadPhase"] as? String ?? ""
            let reload = ["parse", "apply"].first { $0 == reloadPhase }
            let phase = reload.map { "，重载阶段 \($0)" } ?? ""
            TunnelDiagnosticEvents.append("上次隧道可能因内存压力退出，Go 堆 \(heap / 1024) KiB，栈 \(stack / 1024) KiB\(phase)")
        }
        if let report = ClashConsumeGoCrashReport(nil), !report.value.isEmpty {
            TunnelDiagnosticEvents.append("检测到上次隧道的 Go 崩溃报告（\(report.value.utf8.count) 字节）")
        }
        recordStartupExplanation(previous: true)
    }

    private func recordStartupExplanation(previous: Bool) {
        guard let fields = Self.evidenceFields(ClashExplainLastStartup()) else { return }
        let stage = fields["stage"] as? String ?? ""
        // Export only the SDK's phase category and numeric footprint.
        let category = ["bind", "parse", "apply"].first { stage.hasPrefix($0 + ":") } ?? "start"
        let footprint = (fields["footprintBytes"] as? NSNumber)?.int64Value ?? 0
        let label = previous ? "上次隧道启动未完成" : "本次隧道启动失败"
        TunnelDiagnosticEvents.append("\(label)，阶段 \(category)，占用 \(footprint / 1024) KiB")
    }

    private static func evidenceFields(_ payload: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
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
            forSecurityApplicationGroupIdentifier: "group.com.luckyfish.LuckyClash"
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
            self?.handle(path)
        }
        pathMonitor = monitor
        monitor.start(queue: pathQueue)
        _ = firstPath.wait(timeout: .now() + 3)
    }

    /// Called on `pathQueue`.
    private func handle(_ path: Network.NWPath) {
        // Once the tunnel is up, NWPathMonitor can report our own utun as an
        // available interface. Never bind the core's outbound sockets to it.
        let interface = path.status == .satisfied
            ? path.availableInterfaces.first {
                !$0.name.hasPrefix("utun") && $0.type != .loopback
            }
            : nil
        let name = interface?.name ?? ""
        let index = if_nametoindex(name)
        let kind: String
        switch interface?.type {
        case .wifi: kind = "WIFI"
        case .cellular: kind = "CELLULAR"
        case .wiredEthernet: kind = "WIRED"
        default: kind = ""
        }
        let gateways = index == 0 ? "" : path.gateways.compactMap(Self.gatewayAddress)
            .sorted().joined(separator: ",")

        pathLock.lock()
        let wasReady = firstPathArrived
        let sameInterface = defaultInterfaceName == name
        let routeChanged = index != defaultInterfaceIndex || gateways != routers || kind != networkKind
            || path.supportsIPv4 != pathSupportsIPv4 || path.supportsIPv6 != pathSupportsIPv6
        defaultInterfaceName = name
        defaultInterfaceIndex = index
        networkKind = kind
        routers = gateways
        pathExpensive = path.isExpensive
        pathConstrained = path.isConstrained
        pathSupportsIPv4 = path.supportsIPv4
        pathSupportsIPv6 = path.supportsIPv6
        let listener = interfaceListener
        let signal = index != 0 && !wasReady
        if signal { firstPathArrived = true }
        pathLock.unlock()

        if routeChanged {
            ClashSetNetworkIdentity(kind, gateways, nil, nil, nil)
        }
        // The SDK refreshes scoped DNS and resets sessions on interface
        // changes. A gateway change can leave the interface name intact.
        listener?.updateDefaultInterface(
            name, interfaceIndex: Int32(bitPattern: index),
            isExpensive: path.isExpensive, isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6
        )
        if signal { firstPath.signal() }
        if routeChanged {
            routeRecovery?.cancel()
            if wasReady, sameInterface, index != 0 {
                let work = DispatchWorkItem { [weak self] in
                    self?.lifecycle.async { [weak self] in self?.recoverSameInterfaceRoute() }
                }
                routeRecovery = work
                pathQueue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
            }
        }
    }

    private static func gatewayAddress(_ endpoint: Network.NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)".split(separator: "%").first.map(String.init)
        default: return nil
        }
    }

    private func recoverSameInterfaceRoute() {
        guard service != nil, let socketPath else { return }
        if let client = ClashNewAPIClient(socketPath, APIControlHandler(), nil) {
            defer { client.close() }
            try? client.flushDNSCache()
        }
        ClashCloseAllConnections()
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
        let protocolSettings = (provider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let bypassPrivate = protocolSettings?[TunnelNetworkOptions.bypassPrivate] as? Bool ?? false

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
            if bypassPrivate {
                let routes = [
                    NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
                    NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
                    NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")
                ]
                ipv4.excludedRoutes = (ipv4.excludedRoutes ?? []) + routes
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
            if bypassPrivate {
                let local = NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7)
                // Keep the tunnel's own ULA prefix routable via its more specific connected route.
                ipv6.excludedRoutes = (ipv6.excludedRoutes ?? []) + [local]
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

private final class APIControlHandler: NSObject, ClashAPIClientHandlerProtocol {
    func connected() {}
    func disconnected(_ message: String?) {}
    func writeLogs(_ message: String?) {}
    func writeConnections(_ message: String?) {}
    func writeTraffic(_ message: String?) {}
    func writeMemory(_ message: String?) {}
    func writeMode(_ message: String?) {}
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
