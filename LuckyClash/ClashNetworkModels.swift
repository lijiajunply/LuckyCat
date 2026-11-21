import Foundation

/// One active connection reported by the tunnel's Clash core through its Unix
/// control socket. Fields mirror the core's `/connections` snapshot. Decoding
/// is intentionally lenient: the core may omit fields, and its port values are
/// JSON strings while older builds emitted numbers.
nonisolated struct ClashConnection: Identifiable, Equatable, Sendable {
    nonisolated struct Metadata: Equatable, Sendable {
        var network = ""
        var type = ""
        var host = ""
        var sourceIP = ""
        var destinationIP = ""
        var sourcePort = ""
        var destinationPort = ""
        var dnsMode = ""
        var process = ""
        var processPath = ""
        var sniffHost = ""
        var sourceGeoIP: [String] = []
        var destinationGeoIP: [String] = []
        var remoteDestination = ""
    }

    let id: String
    var metadata = Metadata()
    var upload: UInt64 = 0
    var download: UInt64 = 0
    var start: Date?
    var chains: [String] = []
    var rule = ""
    var rulePayload = ""

    /// The most specific destination the core knows about.
    var destinationName: String {
        if !metadata.host.isEmpty { return metadata.host }
        if !metadata.sniffHost.isEmpty { return metadata.sniffHost }
        if !metadata.destinationIP.isEmpty { return metadata.destinationIP }
        return "未知目标"
    }

    var destinationWithPort: String {
        guard !metadata.destinationPort.isEmpty else { return destinationName }
        return "\(destinationName):\(metadata.destinationPort)"
    }

    /// The outbound proxy the core actually used, or `DIRECT` / `REJECT`.
    var outboundName: String {
        chains.last.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
    }

    var ruleSummary: String {
        rulePayload.isEmpty ? rule : "\(rule) \(rulePayload)"
    }

    var isDirect: Bool {
        guard let last = chains.last?.uppercased() else { return true }
        return last == "DIRECT"
    }

    var isRejected: Bool {
        chains.last?.uppercased() == "REJECT"
    }
}

nonisolated struct ClashConnectionsSnapshot: Equatable, Sendable {
    var downloadTotal: UInt64 = 0
    var uploadTotal: UInt64 = 0
    var connections: [ClashConnection] = []
}

nonisolated struct ClashTrafficRates: Equatable, Sendable {
    var upload: Int64 = 0
    var download: Int64 = 0
}

nonisolated struct ClashLogEntry: Identifiable, Equatable, Sendable {
    nonisolated enum Level: String, CaseIterable, Sendable {
        case debug
        case info
        case warning
        case error
        case silent

        init(label: String) {
            switch label.lowercased() {
            case "debug": self = .debug
            case "warn", "warning": self = .warning
            case "err", "error": self = .error
            case "silent": self = .silent
            default: self = .info
            }
        }

        var title: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO"
            case .warning: "WARN"
            case .error: "ERROR"
            case .silent: "SILENT"
            }
        }
    }

    let id: UUID
    var date: Date
    var level: Level
    var payload: String
    var tag: String?
}

/// Decodes the JSON frames the Clash core pushes over its control socket.
nonisolated enum ClashLiveParsing {
    static func snapshot(from message: String) -> ClashConnectionsSnapshot? {
        guard let root = jsonObject(from: message) else { return nil }
        if let dictionary = root as? [String: Any] {
            guard dictionary["connections"] is [Any]
                || dictionary["downloadTotal"] != nil
                || dictionary["uploadTotal"] != nil else { return nil }
            var snapshot = ClashConnectionsSnapshot(
                downloadTotal: uint64(dictionary["downloadTotal"]),
                uploadTotal: uint64(dictionary["uploadTotal"])
            )
            for item in dictionary["connections"] as? [Any] ?? [] {
                if let connection = connection(from: item) {
                    snapshot.connections.append(connection)
                }
            }
            return snapshot
        }
        if let items = root as? [Any] {
            return ClashConnectionsSnapshot(connections: items.compactMap(connection(from:)))
        }
        return nil
    }

    static func connection(from value: Any) -> ClashConnection? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let id = string(dictionary["id"])
        guard !id.isEmpty else { return nil }

        var connection = ClashConnection(id: id)
        connection.upload = uint64(dictionary["upload"])
        connection.download = uint64(dictionary["download"])
        connection.start = date(dictionary["start"])
        connection.chains = strings(dictionary["chains"])
        connection.rule = string(dictionary["rule"])
        connection.rulePayload = string(dictionary["rulePayload"])

        if let metadata = dictionary["metadata"] as? [String: Any] {
            connection.metadata.network = string(metadata["network"])
            connection.metadata.type = string(metadata["type"])
            connection.metadata.host = string(metadata["host"])
            connection.metadata.sourceIP = string(metadata["sourceIP"])
            connection.metadata.destinationIP = string(metadata["destinationIP"])
            connection.metadata.sourcePort = string(metadata["sourcePort"])
            connection.metadata.destinationPort = string(metadata["destinationPort"])
            connection.metadata.dnsMode = string(metadata["dnsMode"])
            connection.metadata.process = string(metadata["process"])
            connection.metadata.processPath = string(metadata["processPath"])
            connection.metadata.sniffHost = string(metadata["sniffHost"])
            connection.metadata.sourceGeoIP = strings(metadata["sourceGeoIP"])
            connection.metadata.destinationGeoIP = strings(metadata["destinationGeoIP"])
            connection.metadata.remoteDestination = string(metadata["remoteDestination"])
        }
        return connection
    }

    /// The core writes one `{"type": "info", "payload": "..."}` frame per log
    /// line, but the bridge can also deliver batches. Both shapes, and plain
    /// text, are accepted so a transport change cannot blank the page.
    static func logs(from message: String, at date: Date = .now) -> [ClashLogEntry] {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        if let root = jsonObject(from: text) {
            if let items = root as? [Any] {
                return items.compactMap { logEntry(from: $0, at: date) }
            }
            if let entry = logEntry(from: root, at: date) {
                return [entry]
            }
        }

        let lines = text.split(whereSeparator: \.isNewline)
        if lines.count > 1 {
            return lines.flatMap { line -> [ClashLogEntry] in
                let part = String(line)
                if let root = jsonObject(from: part), let entry = logEntry(from: root, at: date) {
                    return [entry]
                }
                return [rawEntry(part, at: date)].compactMap { $0 }
            }
        }
        return [rawEntry(text, at: date)].compactMap { $0 }
    }

    static func logEntry(from value: Any, at date: Date) -> ClashLogEntry? {
        guard let dictionary = value as? [String: Any] else { return nil }
        var label = string(dictionary["type"])
        if label.isEmpty { label = string(dictionary["level"]) }
        var payload = string(dictionary["payload"])
        if payload.isEmpty { payload = string(dictionary["message"]) }
        return entry(label: label, payload: payload, at: date)
    }

    static func traffic(from message: String) -> ClashTrafficRates? {
        guard let dictionary = jsonObject(from: message) as? [String: Any] else { return nil }
        return ClashTrafficRates(
            upload: int64(dictionary["up"]),
            download: int64(dictionary["down"])
        )
    }

    // MARK: - Helpers

    private static func rawEntry(_ text: String, at date: Date) -> ClashLogEntry? {
        entry(label: "info", payload: strippingANSI(text), at: date)
    }

    private static func entry(label: String, payload: String, at date: Date) -> ClashLogEntry? {
        let message = strippingANSI(payload)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        return ClashLogEntry(
            id: UUID(),
            date: date,
            level: ClashLogEntry.Level(label: label),
            payload: message,
            tag: tag(from: message)
        )
    }

    /// Core logs frequently start with a transport or rule tag such as
    /// `[TCP]`, which reads better as a badge than as part of the line.
    private static func tag(from message: String) -> String? {
        guard message.hasPrefix("["), let end = message.firstIndex(of: "]") else { return nil }
        let value = message[message.index(after: message.startIndex)..<end]
        return value.isEmpty ? nil : String(value)
    }

    private static func strippingANSI(_ text: String) -> String {
        guard text.contains("\u{001B}") else { return text }
        return text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression
        )
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        case let texts as [Any]: texts.compactMap { $0 as? String }.joined()
        default: ""
        }
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    static func uint64(_ value: Any?) -> UInt64 {
        switch value {
        case let number as NSNumber: number.uint64Value
        case let text as String: UInt64(text) ?? 0
        default: 0
        }
    }

    static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber: number.int64Value
        case let text as String: Int64(text) ?? 0
        default: 0
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let text = value as? String, !text.isEmpty {
            if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
                return parsed
            }
            if let parsed = try? Date.ISO8601FormatStyle().parse(text) {
                return parsed
            }
            return nil
        }
        if let number = value as? NSNumber, number.doubleValue > 0 {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        return nil
    }
}
