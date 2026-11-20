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
    }
}
