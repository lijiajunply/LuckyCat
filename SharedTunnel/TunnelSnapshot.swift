import Foundation

struct TunnelSnapshot: Codable {
    static let schema = 2
    static let supportedSchemas: Set<Int> = [1, 2]
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
    let routePlan: RoutePlan?

    private struct Credentials: Codable {
        let privateKey: String
        let peerPublicKey: String
    }

    static func save(
        _ configuration: PrototypeConfiguration,
        profileID: UUID,
        revision: UUID,
        routePlan: RoutePlan? = nil
    ) throws {
        let snapshot = Self(
            schemaVersion: schema, profileID: profileID, revision: revision,
            endpointAddress: configuration.endpointAddress, endpointPort: configuration.endpointPort,
            clientIPv4: configuration.clientIPv4, clientIPv6: configuration.clientIPv6,
            dnsServers: configuration.dnsServers, routePlan: routePlan
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
        try loadTunnel(profileID: profileID, revision: revision).configuration
    }

    static func loadTunnel(
        profileID: UUID, revision: UUID
    ) throws -> (configuration: PrototypeConfiguration, routePlan: RoutePlan?) {
        let snapshot = try record(profileID: profileID, revision: revision)
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
        return (configuration, snapshot.routePlan)
    }

    /// Rewrites only the routing plan, preserving the stored credentials.
    static func saveRoutePlan(_ plan: RoutePlan, profileID: UUID, revision: UUID) throws {
        let snapshot = try record(profileID: profileID, revision: revision)
        let updated = Self(
            schemaVersion: schema, profileID: snapshot.profileID, revision: snapshot.revision,
            endpointAddress: snapshot.endpointAddress, endpointPort: snapshot.endpointPort,
            clientIPv4: snapshot.clientIPv4, clientIPv6: snapshot.clientIPv6,
            dnsServers: snapshot.dnsServers, routePlan: plan
        )
        let url = try file(for: revision)
        try JSONEncoder().encode(updated).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(revision: UUID) {
        if let url = try? file(for: revision) { try? FileManager.default.removeItem(at: url) }
        PrototypeStore.remove(revision: revision)
    }

    private static func record(profileID: UUID, revision: UUID) throws -> Self {
        let url = try file(for: revision)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              supportedSchemas.contains(snapshot.schemaVersion),
              snapshot.profileID == profileID, snapshot.revision == revision else {
            throw PrototypeError.missingConfiguration
        }
        return snapshot
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
