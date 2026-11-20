import Foundation

enum TrafficMode: String, Codable, CaseIterable, Sendable {
    case rule
    case global
    case direct
}
