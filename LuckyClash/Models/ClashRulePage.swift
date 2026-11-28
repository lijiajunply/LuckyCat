import Foundation

nonisolated struct ClashRulePage: Decodable, Sendable {
    struct Rule: Decodable, Identifiable, Sendable {
        struct Statistics: Decodable, Sendable {
            let hitCount: UInt64
        }

        let index: Int
        let type: String
        let rule: String?
        let payload: String?
        let proxy: String?
        let target: String?
        let extra: Statistics?

        var id: Int { index }
        var summary: String {
            rule ?? [type, payload, proxy ?? target].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ",")
        }

        /// A catalog index normally matches the running core's index. Verify
        /// the rule too, so a concurrent reload cannot attach another rule's
        /// counters to this row.
        func addingStatistics(from live: Rule) -> Rule {
            func normalized(_ value: String) -> String {
                value.uppercased().filter { $0.isLetter || $0.isNumber }
            }
            guard index == live.index, normalized(type) == normalized(live.type),
                  (target ?? proxy) == (live.proxy ?? live.target) else { return self }
            if let payload = live.payload, !payload.isEmpty {
                guard let rule, rule.split(separator: ",").contains(where: {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines) == payload
                }) else { return self }
            }
            return Rule(index: index, type: type, rule: rule, payload: payload,
                        proxy: proxy, target: target, extra: live.extra)
        }
    }

    let total: Int
    let matched: Int?
    let noted: Int?
    let rules: [Rule]
    let error: String?

    static func decode(_ payload: String) throws -> Self {
        let page = try JSONDecoder().decode(Self.self, from: Data(payload.utf8))
        if let error = page.error, !error.isEmpty { throw ClashLiveFailure.rejected(error) }
        return page
    }

    func addingStatistics(_ liveRules: [Int: Rule]) -> Self {
        Self(total: total, matched: matched, noted: noted,
             rules: rules.map { rule in liveRules[rule.index].map { rule.addingStatistics(from: $0) } ?? rule },
             error: error)
    }
}

nonisolated struct ClashRuleMatch: Decodable, Sendable {
    let matched: Bool
    let undecided: Bool?
    let rule: String?
    let policy: String?
    let reason: String?
}
