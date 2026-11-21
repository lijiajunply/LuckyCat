import Foundation

/// Stores the complete Clash configuration that the packet tunnel hands to the
/// Clash core. Configuration files contain proxy credentials, so they live in
/// the shared App Group container with file protection and never in logs.
enum ClashTunnelStore {
    static let maximumConfigurationBytes = 8 * 1024 * 1024

    static let engineKey = "engine"
    static let engineClash = "clash"
    static let profileKey = "profileID"
    static let revisionKey = "clashRevision"
    static let selectedGroupKey = "clashSelectedGroup"
    static let selectedNodeKey = "clashSelectedNode"
    static let modeKey = "clashMode"

    private static let group = "group.com.luckyfish.LuckyCat"

    static func save(_ text: String, profileID: UUID, revision: UUID) throws {
        guard let data = text.data(using: .utf8),
              !data.isEmpty, data.count <= maximumConfigurationBytes else {
            throw PrototypeError.missingConfiguration
        }
        let url = try file(for: revision)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static func load(profileID: UUID, revision: UUID) throws -> String {
        let url = try file(for: revision)
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumConfigurationBytes,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw PrototypeError.missingConfiguration
        }
        return text
    }

    static func remove(revision: UUID) {
        if let url = try? file(for: revision) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func file(for revision: UUID) throws -> URL {
        #if targetEnvironment(simulator)
        let root = URL.applicationSupportDirectory
        #else
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
        ) else {
            throw PrototypeError.sharedContainerUnavailable
        }
        #endif
        let directory = root.appending(path: "ClashConfigs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory.appending(path: revision.uuidString + ".yaml")
    }
}
