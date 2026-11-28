import Foundation
import Observation

/// In-memory state for the network page: active connections, kernel logs and
/// live rates pushed by the tunnel's Clash core. Nothing here is persisted;
/// destinations are cleared when the app leaves memory.
@Observable
final class NetworkStore {
    enum Status: Equatable {
        case idle
        case waiting
        case streaming
    }

    static let maximumLogs = 2000

    private(set) var status: Status = .idle
    private(set) var connections: [ClashConnection] = []
    private(set) var logs: [ClashLogEntry] = []
    private(set) var downloadTotal: UInt64 = 0
    private(set) var uploadTotal: UInt64 = 0
    private(set) var downloadRate: Int64 = 0
    private(set) var uploadRate: Int64 = 0
    struct RateSample: Identifiable {
        let id = UUID()
        let date: Date
        let download: Int64
        let upload: Int64
    }

    private(set) var rateHistory: [RateSample] = []
    struct ClosedRequest: Identifiable {
        let connection: ClashConnection
        let closedAt: Date
        var inferredAfterReconnect = false
        var id: String { connection.id }
        var averageRate: Double {
            let duration = closedAt.timeIntervalSince(connection.start ?? closedAt)
            guard duration > 0 else { return 0 }
            return (Double(connection.upload) + Double(connection.download)) / duration
        }

        static func resolve(_ event: ClashConnectionEvent, previous: ClashConnection?,
                            current: ClashConnection?) -> ClosedRequest? {
            guard var connection = event.connection ?? previous ?? current else { return nil }
            // Close events may contain only final counters, while metadata
            // arrived in an earlier event or connection snapshot.
            connection.upload = max(connection.upload, previous?.upload ?? 0, current?.upload ?? 0, event.upload ?? 0)
            connection.download = max(connection.download, previous?.download ?? 0, current?.download ?? 0, event.download ?? 0)
            return ClosedRequest(connection: connection, closedAt: event.closedAt ?? .now)
        }

        static func missingAfterReset(_ batch: ClashConnectionEventBatch,
                                      previous: [String: ClashConnection], at date: Date) -> [ClosedRequest] {
            guard batch.reset else { return [] }
            let activeIDs = Set(batch.events.filter { $0.type == "new" }.map(\.id))
            return previous.filter { !activeIDs.contains($0.key) }.values.map {
                ClosedRequest(connection: $0, closedAt: date, inferredAfterReconnect: true)
            }
        }
    }

    private(set) var requests: [ClosedRequest] = []
    private var eventConnections: [String: ClashConnection] = [:]
    private(set) var memoryFootprint: UInt64?
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var isRunning = false

    @ObservationIgnored private let live: ClashLiveClient
    @ObservationIgnored private var supervisor: Task<Void, Never>?

    init(live: ClashLiveClient) {
        self.live = live
        live.configure(
            onLog: { [weak self] entry in
                Task { @MainActor [weak self] in self?.append(entry) }
            },
            onConnections: { [weak self] snapshot in
                Task { @MainActor [weak self] in self?.apply(snapshot) }
            },
            onTraffic: { [weak self] rates in
                Task { @MainActor [weak self] in self?.apply(rates) }
            },
            onMemory: { [weak self] bytes in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.memoryFootprint = bytes
                }
            },
            onEvents: { [weak self] events in
                Task { @MainActor [weak self] in self?.apply(events) }
            },
            onDisconnect: { [weak self] message in
                Task { @MainActor [weak self] in self?.handleDisconnect(message) }
            }
        )
    }

    // MARK: - Lifecycle

    /// Starts following the tunnel's core. Idempotent; the supervisor keeps
    /// retrying until the tunnel's socket appears and closes the session when
    /// the tunnel goes away.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        rateHistory = []
        eventConnections = [:]
        memoryFootprint = nil
        downloadTotal = 0
        uploadTotal = 0
        lastUpdated = nil
        supervisor = Task { [weak self] in
            await self?.supervise()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        supervisor?.cancel()
        supervisor = nil
        memoryFootprint = nil
        downloadRate = 0
        uploadRate = 0
        if status == .streaming || status == .waiting {
            status = .idle
        }
    }

    private func supervise() async {
        var holding = false
        defer { if holding { live.release() } }

        while !Task.isCancelled {
            if !holding {
                do {
                    try await live.acquire()
                    holding = true
                    if Task.isCancelled { return }
                    if status != .streaming { status = .streaming }
                    errorMessage = nil
                } catch {
                    if Task.isCancelled { return }
                    status = .waiting
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
            }

            if !live.isOpen {
                live.release()
                holding = false
                status = .waiting
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Actions

    func closeConnection(_ id: String) async {
        do {
            try await live.closeConnection(id: id)
            connections.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeAllConnections() async {
        do {
            try await live.closeAllConnections()
            connections = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearRequests() {
        requests.removeAll()
    }

    func clearLogs() {
        logs.removeAll()
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Stream updates

    private func append(_ entry: ClashLogEntry) {
        guard isRunning else { return }
        logs.append(entry)
        if logs.count > Self.maximumLogs {
            logs.removeFirst(logs.count - Self.maximumLogs)
        }
    }

    private func apply(_ snapshot: ClashConnectionsSnapshot) {
        guard isRunning else { return }
        connections = snapshot.connections
        downloadTotal = snapshot.downloadTotal
        uploadTotal = snapshot.uploadTotal
        lastUpdated = .now
        if isRunning, status != .streaming { status = .streaming }
    }

    private func apply(_ batch: ClashConnectionEventBatch) {
        guard isRunning else { return }
        if batch.reset {
            // A reset contains all connections still open. Any previously
            // observed connection missing from it ended while the stream was
            // disconnected; the exact close time is unknown.
            for request in ClosedRequest.missingAfterReset(batch, previous: eventConnections, at: .now) {
                requests.removeAll { $0.id == request.id }
                requests.append(request)
            }
            if requests.count > 2000 { requests.removeFirst(requests.count - 2000) }
            eventConnections.removeAll()
        }
        for event in batch.events {
            switch event.type {
            case "new":
                if let connection = event.connection { eventConnections[event.id] = connection }
            case "update":
                guard var connection = eventConnections[event.id] else { continue }
                if let upload = event.upload { connection.upload = upload }
                if let download = event.download { connection.download = download }
                eventConnections[event.id] = connection
            case "closed":
                let previous = eventConnections.removeValue(forKey: event.id)
                guard let request = ClosedRequest.resolve(event, previous: previous,
                    current: connections.first(where: { $0.id == event.id })) else { continue }
                requests.removeAll { $0.id == event.id }
                requests.append(request)
                if requests.count > 2000 { requests.removeFirst(requests.count - 2000) }
            default:
                break
            }
        }
    }

    private func apply(_ rates: ClashTrafficRates) {
        guard isRunning else { return }
        rateHistory.append(RateSample(date: .now, download: max(0, rates.download), upload: max(0, rates.upload)))
        if rateHistory.count > 60 { rateHistory.removeFirst(rateHistory.count - 60) }
        uploadRate = rates.upload
        downloadRate = rates.download
        if isRunning, status != .streaming { status = .streaming }
    }

    private func handleDisconnect(_ message: String?) {
        if isRunning {
            status = .waiting
        }
        if let message, !message.isEmpty {
            errorMessage = message
        }
    }
}

#if DEBUG
extension NetworkStore {
    /// Seeds the page for SwiftUI previews without opening a socket.
    func seed(
        status: Status = .streaming,
        connections: [ClashConnection] = PreviewSamples.connections,
        logs: [ClashLogEntry] = PreviewSamples.logs,
        downloadTotal: UInt64 = 86_000_000,
        uploadTotal: UInt64 = 12_000_000,
        downloadRate: Int64 = 240_000,
        uploadRate: Int64 = 32_000
    ) {
        self.status = status
        self.connections = connections
        self.logs = logs
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        lastUpdated = .now
    }
}
#endif
