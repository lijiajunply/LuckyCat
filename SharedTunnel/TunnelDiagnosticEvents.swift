import Foundation

/// A small, protected outbox for extension events. The app and extension
/// never rewrite each other's diagnostic history.
nonisolated enum TunnelDiagnosticEvents {
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
