import Foundation

struct Profile: Codable, Identifiable {
    struct Node: Codable, Identifiable {
        let id: UUID // Immutable snapshot revision.
        let name: String
        let endpoint: String
    }

    let id: UUID
    let name: String
    let nodes: [Node]
    var selectedNodeID: UUID

    var selectedNode: Node? { nodes.first { $0.id == selectedNodeID } }
}

struct ProfileLibrary: Codable {
    var profiles: [Profile] = []
    var selectedProfileID: UUID?

    var selectedProfile: Profile? { profiles.first { $0.id == selectedProfileID } }

    static func load() throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "Profiles.json")
}
