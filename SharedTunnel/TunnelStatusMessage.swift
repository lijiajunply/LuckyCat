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
    }
}
