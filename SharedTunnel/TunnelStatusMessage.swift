import Foundation

enum TunnelStatusMessage {
    static let version = 1

    struct Request: Codable {
        let version: Int
        let id: UUID
    }

    struct Reply: Codable {
        let version: Int
        let id: UUID
        let ready: Bool
        /// Aggregated wireguard-go counters. Older extensions omit them.
        let bytesIn: UInt64?
        let bytesOut: UInt64?
        let runningProfileID: UUID?
    }
}

nonisolated enum TunnelReloadMessage {
    static let version = 1
    static let maximumBytes = 16 * 1024

    struct Selection: Codable {
        let profileID: UUID
        let revision: UUID
        let group: String?
        let node: String?
        let mode: TrafficMode?
        let selections: [String: String]?

        var groupSelections: [String: String] {
            if let selections { return selections }
            if let group, let node, !group.isEmpty, !node.isEmpty { return [group: node] }
            return [:]
        }

        func configuration() throws -> String {
            let text = try ClashTunnelStore.load(profileID: profileID, revision: revision)
            return mode.map { ClashModeOverride.apply($0, to: text) } ?? text
        }
    }

    struct Request: Codable {
        let version: Int
        let id: UUID
        let selection: Selection
    }

    enum Outcome: String, Codable {
        case applied
        case rejected
        case restart
    }

    struct Reply: Codable {
        let version: Int
        let id: UUID
        let outcome: Outcome
        let message: String?
    }
}

nonisolated enum TunnelMemoryMessage {
    struct Request: Codable {
        let version: Int
        let id: UUID
        let freeMemory: Bool
    }
    struct Reply: Codable {
        let version: Int
        let id: UUID
    }
}
