import Foundation

enum ProxyShareCredentials {
    static func validUsername(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 &&
        value.trimmingCharacters(in: .whitespacesAndNewlines) == value &&
        !value.contains(":") && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func validPassword(_ value: String) -> Bool {
        (1...255).contains(value.utf8.count) &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

nonisolated struct ProxyShareStatus: Decodable, Sendable {
    let enabled: Bool
    let port: Int
    let protocols: [String]
    let authenticationRequired: Bool
}
