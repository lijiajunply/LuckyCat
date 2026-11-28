import Foundation
import CryptoKit

/// A small, protected outbox for extension events. The app and extension
/// never rewrite each other's diagnostic history.
nonisolated enum TunnelDiagnosticEvents {
    /// A bounded fingerprint and fixed categories avoid placing raw crash
    /// text, which may contain configuration data, into exported diagnostics.
    static func crashSummary(_ report: String) -> String {
        let lower = report.lowercased()
        let category: String
        if lower.contains("out of memory") { category = "内存不足" }
        else if lower.contains("concurrent map") { category = "并发映射" }
        else if lower.contains("invalid memory address") || lower.contains("nil pointer dereference") { category = "无效内存访问" }
        else if lower.contains("stack overflow") { category = "栈溢出" }
        else { category = "其他" }
        let digest = SHA256.hash(data: Data(report.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "检测到上次隧道的 Go 崩溃：\(category)，标识 \(digest)，报告 \(report.utf8.count) 字节"
    }
    struct Event: Codable {
        let id: UUID
        let timestamp: Date
        let message: String
    }

    static func append(_ message: String) {
        let event = Event(id: UUID(), timestamp: .now, message: message)
        guard let directory = directory(),
              let data = try? JSONEncoder().encode(event) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: event.id.uuidString), options: [
                .atomic, .completeFileProtectionUntilFirstUserAuthentication
            ])
        } catch { return }

        let files = pending()
        for entry in files.dropLast(40) { acknowledge(entry.url) }
    }

    static func pending() -> [(url: URL, event: Event)] {
        guard let directory = directory(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              ) else { return [] }
        return files.compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: url),
                  let event = try? JSONDecoder().decode(Event.self, from: data) else { return nil }
            return (url, event)
        }.sorted { $0.event.timestamp < $1.event.timestamp }
    }

    static func acknowledge(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func directory() -> URL? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.luckyfish.LuckyClash")?
            .appending(path: "TunnelDiagnostics", directoryHint: .isDirectory)
        #endif
    }
}
