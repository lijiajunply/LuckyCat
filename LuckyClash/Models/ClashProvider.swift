import Foundation

nonisolated struct ClashProviderPayload: Decodable, Sendable {
    struct Node: Decodable, Sendable {
        let name: String
    }

    struct Usage: Decodable, Sendable {
        let upload: Int64?
        let download: Int64?
        let total: Int64?
        let expire: Int64?

        enum CodingKeys: String, CodingKey {
            case upload = "Upload"
            case download = "Download"
            case total = "Total"
            case expire = "Expire"
        }
    }

    let vehicleType: String?
    let proxies: [Node]?
    let ruleCount: Int?
    let updatedAt: String?
    let subscriptionInfo: Usage?

    static func decode(_ json: String) throws -> [String: Self] {
        struct Envelope: Decodable { let providers: [String: ClashProviderPayload] }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).providers
    }

    var updateDate: Date? {
        guard let updatedAt, !updatedAt.hasPrefix("0001-") else { return nil }
        return try? Date(updatedAt, strategy: .iso8601)
    }
}

nonisolated struct ClashProvider: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case proxy
        case rule
    }

    let name: String
    let kind: Kind
    let payload: ClashProviderPayload

    var id: String { kind.rawValue + ":" + name }
}
