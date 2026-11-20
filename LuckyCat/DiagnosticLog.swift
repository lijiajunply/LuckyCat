import Foundation
import Observation

struct DiagnosticRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let event: String
}

@Observable
final class DiagnosticLog {
    static let maximumRecords = 200
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let maximumEventLength = 160

    private(set) var records: [DiagnosticRecord] = []

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let now: () -> Date

    init(fileURL: URL? = DiagnosticLog.defaultFileURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    func append(_ event: String) {
        let sanitized = Self.sanitize(event)
        guard !sanitized.isEmpty else { return }
        records.append(DiagnosticRecord(id: UUID(), timestamp: now(), event: sanitized))
        prune()
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    var exportText: String {
        records.map { "\($0.timestamp.formatted(.iso8601))  \($0.event)" }.joined(separator: "\n")
    }

    /// Keeps records free of line breaks and control characters so exports stay one event per line.
    static func sanitize(_ event: String) -> String {
        let cleaned = event.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }
        .joined()
        let trimmed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(trimmed.prefix(maximumEventLength))
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DiagnosticRecord].self, from: data) else { return }
        records = decoded
        prune()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        records.removeAll { $0.timestamp < cutoff }
        if records.count > Self.maximumRecords {
            records.removeFirst(records.count - Self.maximumRecords)
        }
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(records).write(
            to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Diagnostics.json")
    }
}
