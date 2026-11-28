import Foundation

nonisolated struct ProxyShareStatus: Decodable, Sendable {
    let enabled: Bool
    let port: Int
    let protocols: [String]
    let authenticationRequired: Bool
}
