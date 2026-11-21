import Clash
import Darwin
import Foundation
import Network

nonisolated enum LatencyState: Equatable, Sendable {
    case untested
    case testing
    case value(Int)
    case failed
}

nonisolated enum ClashLatencyFailure: LocalizedError {
    case storage
    case setup(String)
    case engine(String)
    case api(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .storage:
            "无法准备延迟测试所需的本机存储。"
        case .setup(let message):
            "无法初始化延迟测试内核（\(message)）。"
        case .engine(let message):
            "延迟测试内核拒绝了该配置：\(message)"
        case .api(let message):
            "无法连接延迟测试内核：\(message)"
        case .unavailable:
            "延迟测试内核没有就绪，请稍后重试。"
        }
    }
}

/// Runs a short-lived Clash core inside the app process and asks its local
/// control socket for URL-test delays. The engine never installs a real tunnel:
/// it uses a private socket pair for the TUN callback and strips listeners and
/// rules out of the configuration, so it can only measure outbound latency.
nonisolated final class ClashLatencyTester: @unchecked Sendable {
    static let shared = ClashLatencyTester()

    /// Used when the profile does not configure a url-test endpoint. Apple's
    /// captive-portal probe is reachable on most networks, including mainland
    /// China, where gstatic is commonly blocked.
    nonisolated static let defaultTestURL = "https://www.apple.com/library/test/success.html"

    private static let maximumConcurrentTests = 5
    private static let socketWaitIterations = 60
    private static let socketPollInterval: TimeInterval = 0.05

    private static let setupLock = NSLock()
    nonisolated(unsafe) private static var setupDone = false
    nonisolated(unsafe) private static var setupFailure: Error?

    private let queue = DispatchQueue(label: "com.luckyfish.LuckyClash.latency")
    private let stateLock = NSLock()
    private var cancelRequested = false

    func cancel() {
        stateLock.lock()
        cancelRequested = true
        stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelRequested
    }

    func measure(
        configuration: String,
        nodes: [String],
        testURL: String = ClashLatencyTester.defaultTestURL,
        progress: @escaping @Sendable (_ name: String, _ delay: Int) -> Void
    ) async throws -> [String: Int] {
        let endpoint = testURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = endpoint.isEmpty ? Self.defaultTestURL : endpoint
        stateLock.lock()
        cancelRequested = false
        stateLock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(
                        returning: try run(
                            configuration: configuration, nodes: nodes,
                            testURL: url, progress: progress
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Session

    private func run(
        configuration: String,
        nodes: [String],
        testURL: String,
        progress: @escaping @Sendable (_ name: String, _ delay: Int) -> Void
    ) throws -> [String: Int] {
        _ = try Self.prepareEngine()
        let sanitized = try Self.sanitized(configuration)

        let platform = LatencyPlatform()
        var error: NSError?
        guard let service = ClashNewService(platform, &error) else {
            throw ClashLatencyFailure.setup(error?.localizedDescription ?? "service")
        }

        let socketPath = ClashAPIPath()
        defer {
            try? service.close()
            platform.stop()
            if !socketPath.isEmpty {
                try? FileManager.default.removeItem(atPath: socketPath)
            }
        }

        let outcome = service.startClassified(sanitized)
        if let errorClass = outcome?.errorClass, !errorClass.isEmpty,
           errorClass != ClashCoreOutcomeCommitted {
            throw ClashLatencyFailure.engine(outcome?.message ?? "未知错误")
        }

        guard Self.waitForSocket(socketPath) else {
            throw ClashLatencyFailure.unavailable
        }

        let handler = LatencyAPIHandler()
        guard let client = ClashNewAPIClient(socketPath, handler, &error), error == nil else {
            throw ClashLatencyFailure.api(error?.localizedDescription ?? "client")
        }
        defer { client.close() }

        var connected = false
        var attempts = 0
        while !connected, attempts < Self.socketWaitIterations {
            attempts += 1
            do {
                try client.connect()
                connected = true
            } catch {
                Thread.sleep(forTimeInterval: Self.socketPollInterval)
            }
        }
        guard connected else { throw ClashLatencyFailure.unavailable }

        return Self.measure(
            client: client, nodes: nodes, testURL: testURL, progress: progress,
            cancelled: { self.isCancelled }
        )
    }

    private static func measure(
        client: ClashAPIClient,
        nodes: [String],
        testURL: String,
        progress: @escaping @Sendable (_ name: String, _ delay: Int) -> Void,
        cancelled: @escaping @Sendable () -> Bool
    ) -> [String: Int] {
        let box = ClientBox(client: client)
        let results = DelayResults()
        let workers = DispatchQueue(label: "com.luckyfish.LuckyClash.latency.tests", attributes: .concurrent)
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(
            value: max(1, min(maximumConcurrentTests, nodes.count))
        )

        for name in nodes {
            if cancelled() { break }
            semaphore.wait()
            group.enter()
            workers.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                guard !cancelled() else { return }
                var delay: Int = -1
                do {
                    try box.client.urlTest(name, testURL: testURL, ret0_: &delay)
                } catch {
                    delay = -1
                }
                results.set(delay, for: name)
                progress(name, delay)
            }
        }
        group.wait()
        return results.snapshot
    }

    // MARK: - Engine lifecycle

    private static func prepareEngine() throws -> URL {
        let base = try engineDirectory()
        setupLock.lock()
        defer { setupLock.unlock() }
        if setupDone {
            if let setupFailure { throw setupFailure }
            return base
        }

        let working = base.appending(path: "working", directoryHint: .isDirectory)
        let temp = base.appending(path: "temp", directoryHint: .isDirectory)
        let cache = base.appending(path: "cache", directoryHint: .isDirectory)
        do {
            for directory in [working, temp, cache] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            }
        } catch {
            setupDone = true
            setupFailure = ClashLatencyFailure.storage
            throw ClashLatencyFailure.storage
        }

        let options = ClashSetupOptions()
        options.basePath = base.path
        options.workingPath = working.path
        options.tempPath = temp.path
        options.runtimeProfile = ClashRuntimeProfileIOSPacketTunnel
        options.timeZone = TimeZone.current.identifier
        options.systemDNSServerLines = ClashSystemResolverLines()
        options.logMaxLines = 20
        options.startupPhaseLogPath = base.appending(path: "startup.log").path
        options.includeAllNetworks = false
        options.disablePersistentCache = false
        options.persistentCacheDirectory = cache.path

        var error: NSError?
        let ok = ClashSetup(options, &error)
        setupDone = true
        if !ok {
            let failure = ClashLatencyFailure.setup(
                error?.localizedDescription ?? "ClashSetup"
            )
            setupFailure = failure
            throw failure
        }
        return base
    }

    private static func engineDirectory() throws -> URL {
        let root: URL
        #if targetEnvironment(simulator)
        root = URL(fileURLWithPath: "/tmp/lc-latency-engine", isDirectory: true)
        #else
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.luckyfish.LuckyClash"
        ) else {
            throw ClashLatencyFailure.storage
        }
        // The core binds `clash.sock` directly below this path. The App Group
        // container plus "/LatencyEngine" would exceed Darwin's 103-byte Unix
        // socket limit, so keep the directory name as short as possible.
        root = container.appending(path: "lt", directoryHint: .isDirectory)
        #endif
        // Keep it well under Darwin's 103-byte Unix socket limit.
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw ClashLatencyFailure.storage
        }
        return root
    }

    private static func waitForSocket(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        for _ in 0..<socketWaitIterations {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: socketPollInterval)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Configuration

    private static let strippedKeys = [
        "port", "socks-port", "mixed-port", "redir-port", "tproxy-port",
        "allow-lan", "external-controller", "external-controller-tls",
        "external-controller-unix", "external-controller-pipe", "external-ui",
        "secret", "authentication", "listeners", "tunnels", "rule-providers",
        "geox-url"
    ]

    /// Removes everything that could open a local listener or require rule
    /// data. URL tests only need the proxies and their providers.
    private static func sanitized(_ yaml: String) throws -> String {
        var parseError: NSError?
        guard let parsed = ClashYamlToJSON(yaml, &parseError),
              let data = parsed.value.data(using: .utf8),
              var document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClashLatencyFailure.engine(
                parseError?.localizedDescription ?? "无法解析配置"
            )
        }

        for key in strippedKeys {
            document.removeValue(forKey: key)
        }
        document["rules"] = ["MATCH,DIRECT"]
        document["geodata-mode"] = false
        // The test engine is outside the tunnel, so the profile's DNS may point
        // at servers only reachable through it. Let the core use the system
        // resolver while it measures outbound delays.
        document.removeValue(forKey: "dns")

        if var tun = document["tun"] as? [String: Any] {
            tun["enable"] = true
            tun.removeValue(forKey: "device")
            document["tun"] = tun
        }

        guard let json = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let encoded = ClashJSONToYaml(String(decoding: json, as: UTF8.self), nil) else {
            throw ClashLatencyFailure.engine("无法生成延迟测试配置")
        }
        return encoded.value
    }
}

// MARK: - Helpers

private nonisolated final class ClientBox: @unchecked Sendable {
    let client: ClashAPIClient

    init(client: ClashAPIClient) {
        self.client = client
    }
}

private nonisolated final class DelayResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func set(_ delay: Int, for name: String) {
        lock.lock()
        values[name] = delay
        lock.unlock()
    }

    var snapshot: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private nonisolated final class LatencyAPIHandler: NSObject, ClashAPIClientHandlerProtocol {
    func connected() {}
    func disconnected(_ message: String?) {}
    func writeConnections(_ message: String?) {}
    func writeLogs(_ message: String?) {}
    func writeMemory(_ message: String?) {}
    func writeMode(_ message: String?) {}
    func writeTraffic(_ message: String?) {}
}

// MARK: - Platform

private nonisolated final class LatencyPlatform: NSObject, ClashPlatformInterfaceProtocol {
    private let pathQueue = DispatchQueue(label: "com.luckyfish.LuckyClash.latency.path")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var listener: (any ClashInterfaceUpdateListenerProtocol)?
    private var interfaceName = ""
    private var interfaceIndex: UInt32 = 0
    private var tunDescriptors: [Int32] = []

    func writeLog(_ message: String?) {}

    func tunFailed(_ reason: String?) {}

    func openTun(
        _ options: (any ClashTunOptionsProtocol)?,
        ret0_: UnsafeMutablePointer<Int32>?
    ) throws {
        guard let ret0_ else { throw ClashLatencyFailure.engine("缺少 TUN 描述符") }
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else {
            throw ClashLatencyFailure.engine("无法创建测试用 TUN 描述符")
        }
        lock.lock()
        tunDescriptors = pair
        lock.unlock()
        ret0_.pointee = pair[0]
    }

    func usePlatformAutoDetectControl() -> Bool { true }

    func autoDetectControl(_ fd: Int32) throws {
        lock.lock()
        let index = interfaceIndex
        lock.unlock()
        guard index != 0 else { return }
        var value = index
        let size = socklen_t(MemoryLayout<UInt32>.size)
        _ = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &value, size)
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &value, size)
    }

    func startDefaultInterfaceMonitor(
        _ listener: (any ClashInterfaceUpdateListenerProtocol)?
    ) throws {
        lock.lock()
        self.listener = listener
        lock.unlock()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        self.monitor = monitor
        monitor.start(queue: pathQueue)
    }

    func closeDefaultInterfaceMonitor(
        _ listener: (any ClashInterfaceUpdateListenerProtocol)?
    ) throws {
        stop()
    }

    func getInterfaces() throws -> any ClashNetworkInterfaceIteratorProtocol {
        LatencyInterfaceIterator()
    }

    func underNetworkExtension() -> Bool { true }

    func stop() {
        monitor?.cancel()
        monitor = nil
        lock.lock()
        let descriptors = tunDescriptors
        tunDescriptors = []
        listener = nil
        lock.unlock()
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    deinit {
        stop()
    }

    private func update(_ path: Network.NWPath) {
        let interface = path.availableInterfaces.first { !$0.name.hasPrefix("utun") }
        let name = interface?.name ?? ""
        let index = name.isEmpty ? 0 : if_nametoindex(name)

        lock.lock()
        interfaceName = name
        interfaceIndex = index
        let listener = self.listener
        lock.unlock()

        listener?.updateDefaultInterface(
            name,
            interfaceIndex: Int32(bitPattern: index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6
        )
    }
}

private nonisolated final class LatencyInterfaceIterator: NSObject, ClashNetworkInterfaceIteratorProtocol {
    func hasNext() -> Bool { false }
    func len() -> Int32 { 0 }
    func next() -> ClashNetworkInterface? { nil }
}
