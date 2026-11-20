import Foundation

struct TunnelSnapshot: Codable {
    static let schema = 1
    static let profileKey = "profileID"
    static let revisionKey = "snapshotRevision"
    private static let group = "group.com.luckyfish.LuckyCat"

    let schemaVersion: Int
    let profileID: UUID
    let revision: UUID
    let endpointAddress: String
    let endpointPort: UInt16
    let clientIPv4: String
    let clientIPv6: String
    let dnsServers: [String]

    private struct Credentials: Codable {
        let privateKey: String
        let peerPublicKey: String
    }

    static func save(_ configuration: PrototypeConfiguration, profileID: UUID, revision: UUID) throws {
        let snapshot = Self(
            schemaVersion: schema, profileID: profileID, revision: revision,
            endpointAddress: configuration.endpointAddress, endpointPort: configuration.endpointPort,
            clientIPv4: configuration.clientIPv4, clientIPv6: configuration.clientIPv6, dnsServers: configuration.dnsServers
        )
        let credentials = Credentials(privateKey: configuration.privateKey, peerPublicKey: configuration.peerPublicKey)
        let url = try file(for: revision)
        try PrototypeStore.save(credentials, revision: revision)
        do {
            try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            PrototypeStore.remove(revision: revision)
            throw error
        }
    }

    static func load(profileID: UUID, revision: UUID) throws -> PrototypeConfiguration {
        let url = try file(for: revision)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.schemaVersion == schema, snapshot.profileID == profileID, snapshot.revision == revision else {
            throw PrototypeError.missingConfiguration
        }
        let credentialData = try PrototypeStore.data(for: revision)
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: credentialData) else {
            throw PrototypeError.missingConfiguration
        }
        let configuration = PrototypeConfiguration(
            endpointAddress: snapshot.endpointAddress, endpointPort: snapshot.endpointPort,
            clientIPv4: snapshot.clientIPv4, clientIPv6: snapshot.clientIPv6, dnsServers: snapshot.dnsServers,
            privateKey: credentials.privateKey, peerPublicKey: credentials.peerPublicKey
        )
        try configuration.validate()
        return configuration
    }

    static func remove(revision: UUID) {
        if let url = try? file(for: revision) { try? FileManager.default.removeItem(at: url) }
        PrototypeStore.remove(revision: revision)
    }

    private static func file(for revision: UUID) throws -> URL {
        #if targetEnvironment(simulator)
        // The simulator exercises App storage without a provisioned Extension.
        let root = URL.applicationSupportDirectory
        #else
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw PrototypeError.sharedContainerUnavailable
        }
        #endif
        let directory = root.appending(path: "TunnelSnapshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: revision.uuidString + ".json")
    }
}
