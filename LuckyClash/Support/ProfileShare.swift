import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Prepares shareable content for a saved profile: URL subscriptions share
/// their source URL, and all other profiles share their Clash YAML data.
enum ProfileShare {
    enum Payload: Equatable, Sendable {
        case url(URL)
        case yaml(fileName: String, content: String)
    }

    nonisolated static var temporaryShareDirectory: URL {
        FileManager.default.temporaryDirectory.appending(
            path: "SharedProfiles",
            directoryHint: .isDirectory
        )
    }

    static func actionTitle(for profile: Profile) -> String {
        profile.sourceURL != nil ? "分享订阅链接" : "分享 YAML 配置"
    }

    static func payload(
        for profile: Profile,
        loadYAML: ((Profile) throws -> String)? = nil
    ) throws -> Payload {
        if let sourceURL = profile.sourceURL {
            return .url(sourceURL)
        }
        let content = try loadYAML?(profile) ?? yaml(for: profile)
        return .yaml(
            fileName: fileName(for: profile.name),
            content: content
        )
    }

    static func yaml(for profile: Profile) throws -> String {
        try loadYAML(
            profileID: profile.id,
            clashRevision: profile.clashRevision,
            isLegacyWireGuard: profile.resolvedEngine == .wireGuard,
            legacyNodes: profile.nodes.map {
                ProfileYAMLTransferable.LegacyNode(
                    id: $0.id,
                    name: $0.name,
                    endpoint: $0.endpoint
                )
            },
            legacyRules: profile.rules ?? []
        )
    }

    static func loadYAML(
        profileID: UUID,
        clashRevision: UUID?,
        isLegacyWireGuard: Bool,
        legacyNodes: [ProfileYAMLTransferable.LegacyNode],
        legacyRules: [RoutingRule]
    ) throws -> String {
        if let revision = clashRevision {
            return try ClashTunnelStore.load(profileID: profileID, revision: revision)
        }
        guard isLegacyWireGuard else {
            throw PrototypeError.missingConfiguration
        }
        var nodes: [ImportedNode] = []
        for node in legacyNodes {
            guard let configuration = try? TunnelSnapshot.load(
                profileID: profileID,
                revision: node.id
            ) else { continue }
            nodes.append(ImportedNode(
                name: node.name,
                type: "wireguard",
                endpoint: node.endpoint,
                configuration: configuration
            ))
        }
        let converted = try ClashImport.fromLegacy(ImportedConfiguration(
            engine: .wireGuard,
            nodes: nodes,
            rules: legacyRules,
            warnings: []
        ))
        guard let yaml = converted.clashYAML else {
            throw PrototypeError.missingConfiguration
        }
        return yaml
    }

    nonisolated static func fileName(for profileName: String) -> String {
        var base = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = base.lowercased()
        if lower.hasSuffix(".yaml") {
            base = String(base.dropLast(5))
        } else if lower.hasSuffix(".yml") {
            base = String(base.dropLast(4))
        }

        let sanitized = String(base.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar)
                || scalar == "/" || scalar == "\\" || scalar == ":" {
                return "-"
            }
            return Character(scalar)
        })
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))

        let stem = String(sanitized.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "LuckyClash" : stem) + ".yaml"
    }

    nonisolated static func writeTemporaryYAMLFile(
        _ yaml: String,
        fileName: String,
        in baseDirectory: URL = temporaryShareDirectory,
        now: Date = .now
    ) throws -> URL {
        guard let data = yaml.data(using: .utf8), !data.isEmpty else {
            throw PrototypeError.missingConfiguration
        }
        cleanupExpiredFiles(in: baseDirectory, now: now)
        let folder = baseDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appending(path: fileName)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return fileURL
    }

    nonisolated static func cleanupExpiredFiles(
        in baseDirectory: URL = temporaryShareDirectory,
        olderThan age: TimeInterval = 600,
        now: Date = .now
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-age)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}

/// Lazily exports a non-URL profile's Clash YAML configuration as a `.yaml` file
/// when the user invokes the system share sheet.
nonisolated struct ProfileYAMLTransferable: Transferable, Sendable {
    struct LegacyNode: Sendable {
        let id: UUID
        let name: String
        let endpoint: String
    }

    let profileID: UUID
    let fileName: String
    let clashRevision: UUID?
    let isLegacyWireGuard: Bool
    let legacyNodes: [LegacyNode]
    let legacyRules: [RoutingRule]

    @MainActor
    init(profile: Profile) {
        self.profileID = profile.id
        self.fileName = ProfileShare.fileName(for: profile.name)
        self.clashRevision = profile.clashRevision
        self.isLegacyWireGuard = profile.resolvedEngine == .wireGuard
        self.legacyNodes = profile.nodes.map {
            LegacyNode(id: $0.id, name: $0.name, endpoint: $0.endpoint)
        }
        self.legacyRules = profile.rules ?? []
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .yaml) { item in
            let yaml = try await MainActor.run {
                try ProfileShare.loadYAML(
                    profileID: item.profileID,
                    clashRevision: item.clashRevision,
                    isLegacyWireGuard: item.isLegacyWireGuard,
                    legacyNodes: item.legacyNodes,
                    legacyRules: item.legacyRules
                )
            }
            let fileURL = try ProfileShare.writeTemporaryYAMLFile(yaml, fileName: item.fileName)
            return SentTransferredFile(fileURL)
        }
    }
}
