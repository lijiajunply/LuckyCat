import Clash
import Foundation

nonisolated enum ClashLiveFailure: LocalizedError, Equatable {
    case missingSocket
    case unavailable
    case missingGroup
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .missingSocket:
            "内核尚未启动，请先连接 VPN。"
        case .unavailable:
            "当前连接的内核控制通道不可用，请稍后重试。"
        case .missingGroup:
            "该节点不在可手动切换的策略组中，会在下次连接时生效。"
        case .rejected(let message):
            "内核拒绝了操作：\(message)"
        }
    }
}

/// Talks to the Clash core owned by the running packet tunnel. The extension
/// exposes a Unix control socket inside the App Group container; the app reads
/// live connections and logs from it, and applies mode or node changes without
/// restarting the tunnel.
///
/// The transport is a set of websocket streams over that socket, so every call
/// is kept off the main actor and guarded by a serial queue. A small lease
/// count lets the network page hold a long-lived session while one-shot
/// operations (mode, node, latency) borrow the same client.
nonisolated final class ClashLiveClient: @unchecked Sendable {
    /// `<App Group container>/clash.sock`, matching the base path the packet
    /// tunnel hands to `ClashSetup`. The simulator gives each process its own
    /// container, so there is no live channel there.
    static var socketPath: String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.luckyfish.LuckyCat"
        ) else { return nil }
        return root.appending(path: "clash.sock").path
        #endif
    }

    nonisolated(unsafe) private var onLog: (@Sendable (ClashLogEntry) -> Void)?
    nonisolated(unsafe) private var onConnections: (@Sendable (ClashConnectionsSnapshot) -> Void)?
    nonisolated(unsafe) private var onTraffic: (@Sendable (ClashTrafficRates) -> Void)?
    nonisolated(unsafe) private var onDisconnect: (@Sendable (String?) -> Void)?

    private static let maximumConcurrentTests = 5
    private static let logLevel = "info"
    private static let statusInterval: Int64 = 1000

    private let queue = DispatchQueue(label: "com.luckyfish.LuckyCat.clash.live")
    private let stateLock = NSLock()
    private var client: ClashAPIClient?
    private var handler: LiveHandler?
    private var leases = 0
    private var cancelledTests = false

    /// Whether a control session is currently open.
    var isOpen: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return client != nil
    }

    /// Stream callbacks arrive on the core's reader threads. The owner sets
    /// them once, before opening the first session.
    func configure(
        onLog: @escaping @Sendable (ClashLogEntry) -> Void,
        onConnections: @escaping @Sendable (ClashConnectionsSnapshot) -> Void,
        onTraffic: @escaping @Sendable (ClashTrafficRates) -> Void,
        onDisconnect: @escaping @Sendable (String?) -> Void
    ) {
        stateLock.lock()
        self.onLog = onLog
        self.onConnections = onConnections
        self.onTraffic = onTraffic
        self.onDisconnect = onDisconnect
        stateLock.unlock()
    }

    // MARK: - Session

    func acquire() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                stateLock.lock()
                leases += 1
                stateLock.unlock()
                guard currentClient() == nil else {
                    continuation.resume()
                    return
                }
                do {
                    try openLocked()
                    continuation.resume()
                } catch {
                    stateLock.lock()
                    leases = max(0, leases - 1)
                    stateLock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Drops one lease. The session closes when the last lease is gone.
    func release() {
        queue.async { [self] in
            stateLock.lock()
            leases = max(0, leases - 1)
            let remaining = leases
            stateLock.unlock()
            guard remaining == 0 else { return }
            closeLocked()
        }
    }

    // MARK: - Operations

    func setMode(_ mode: TrafficMode) async throws {
        try await using { client in
            _ = try client.setMode(mode.rawValue)
        }
    }

    func select(group: String?, name: String) async throws {
        let group = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !group.isEmpty else { throw ClashLiveFailure.missingGroup }
        try await using { client in
            _ = try client.selectProxy(group, name: name)
        }
    }

    func closeConnection(id: String) async throws {
        try await using { client in
            _ = try client.closeConnection(id)
        }
    }

    func closeAllConnections() async throws {
        try await using { client in
            _ = try client.closeConnections()
        }
    }

    func snapshot() async throws -> ClashConnectionsSnapshot {
        try await using { client in
            var error: NSError?
            let message = client.getConnections(&error)
            if let error { throw error }
            guard let snapshot = ClashLiveParsing.snapshot(from: message) else {
                throw ClashLiveFailure.unavailable
            }
            return snapshot
        }
    }

    /// Runs URL tests through the live core, so delays are measured on the
    /// same path the tunnel is already using.
    func urlTest(
        names: [String],
        testURL: String,
        progress: @escaping @Sendable (String, Int) -> Void
    ) async throws -> [String: Int] {
        let testURL = testURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = testURL.isEmpty ? ClashLatencyTester.defaultTestURL : testURL
        stateLock.withLock {
            cancelledTests = false
        }

        try await acquire()
        defer { release() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Int], Error>) in
            queue.async { [self] in
                guard let client = currentClient() else {
                    continuation.resume(throwing: ClashLiveFailure.unavailable)
                    return
                }
                let results = measure(
                    client: client, names: names, testURL: url, progress: progress
                )
                continuation.resume(returning: results)
            }
        }
    }

    func cancelURLTests() {
        stateLock.lock()
        cancelledTests = true
        stateLock.unlock()
    }

    // MARK: - Session lifecycle

    private func openLocked() throws {
        guard let path = Self.socketPath,
              FileManager.default.fileExists(atPath: path) else {
            throw ClashLiveFailure.missingSocket
        }

        let options = ClashAPIClientOptions()
        options.logLevel = Self.logLevel
        options.statusInterval = Self.statusInterval
        options.addCommand(ClashCommandLog)
        options.addCommand(ClashCommandStatus)
        options.addCommand(ClashCommandConnections)

        let handler = LiveHandler(owner: self)
        var error: NSError?
        guard let client = ClashNewAPIClientWithOptions(path, handler, options, &error) else {
            throw ClashLiveFailure.rejected(error?.localizedDescription ?? "无法创建控制客户端")
        }
        do {
            try client.connect()
        } catch {
            handler.suppressDisconnect()
            client.close()
            throw ClashLiveFailure.rejected(error.localizedDescription)
        }

        stateLock.lock()
        self.handler = handler
        self.client = client
        stateLock.unlock()
    }

    private func closeLocked() {
        stateLock.lock()
        let client = self.client
        let handler = self.handler
        self.client = nil
        self.handler = nil
        stateLock.unlock()
        handler?.suppressDisconnect()
        client?.close()
    }

    /// Called by the stream handler when the core goes away. The client is
    /// released asynchronously so the Go callback can return immediately.
    fileprivate func sessionEnded(_ message: String?) {
        stateLock.lock()
        let client = self.client
        let handler = self.handler
        self.client = nil
        self.handler = nil
        stateLock.unlock()
        handler?.suppressDisconnect()
        if let client {
            let box = ClientBox(client: client)
            queue.async { box.client.close() }
        }
        stateLock.lock()
        let disconnect = onDisconnect
        stateLock.unlock()
        disconnect?(message)
    }

    fileprivate func deliverLog(_ entry: ClashLogEntry) {
        stateLock.lock()
        let sink = onLog
        stateLock.unlock()
        sink?(entry)
    }

    fileprivate func deliverConnections(_ snapshot: ClashConnectionsSnapshot) {
        stateLock.lock()
        let sink = onConnections
        stateLock.unlock()
        sink?(snapshot)
    }

    fileprivate func deliverTraffic(_ rates: ClashTrafficRates) {
        stateLock.lock()
        let sink = onTraffic
        stateLock.unlock()
        sink?(rates)
    }

    private func currentClient() -> ClashAPIClient? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return client
    }

    private func using<T: Sendable>(
        _ body: @escaping @Sendable (ClashAPIClient) throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async { [self] in
                guard let client = currentClient() else {
                    continuation.resume(throwing: ClashLiveFailure.unavailable)
                    return
                }
                do {
                    continuation.resume(returning: try body(client))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Latency

    private func measure(
        client: ClashAPIClient,
        names: [String],
        testURL: String,
        progress: @escaping @Sendable (String, Int) -> Void
    ) -> [String: Int] {
        let box = ClientBox(client: client)
        let results = DelayResults()
        let workers = DispatchQueue(
            label: "com.luckyfish.LuckyCat.live.tests", attributes: .concurrent
        )
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(
            value: max(1, min(Self.maximumConcurrentTests, names.count))
        )

        for name in names {
            if isCancelled { break }
            semaphore.wait()
            group.enter()
            workers.async { [self] in
                defer {
                    semaphore.signal()
                    group.leave()
                }
                guard !isCancelled else { return }
                var delay = -1
                do {
                    _ = try box.client.urlTest(name, testURL: testURL, ret0_: &delay)
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

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelledTests
    }
}

// MARK: - Stream handler

private nonisolated final class LiveHandler: NSObject, ClashAPIClientHandlerProtocol {
    private weak var owner: ClashLiveClient?
    private let lock = NSLock()
    private var suppressed = false

    init(owner: ClashLiveClient) {
        self.owner = owner
    }

    func suppressDisconnect() {
        lock.lock()
        suppressed = true
        lock.unlock()
    }

    private var isSuppressed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppressed
    }

    func connected() {}

    func disconnected(_ message: String?) {
        guard !isSuppressed else { return }
        owner?.sessionEnded(message)
    }

    func writeLogs(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        for entry in ClashLiveParsing.logs(from: message) {
            owner?.deliverLog(entry)
        }
    }

    func writeConnections(_ message: String?) {
        guard let message, let snapshot = ClashLiveParsing.snapshot(from: message) else { return }
        owner?.deliverConnections(snapshot)
    }

    func writeTraffic(_ message: String?) {
        guard let message, let rates = ClashLiveParsing.traffic(from: message) else { return }
        owner?.deliverTraffic(rates)
    }

    func writeMemory(_ message: String?) {}

    func writeMode(_ message: String?) {}
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
