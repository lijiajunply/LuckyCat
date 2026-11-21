import Foundation
import Testing
@testable import LuckyClash

@MainActor
struct RoutePlanTests {
    @Test func globalPlanUsesDefaultRoutesAndTunnelDNS() throws {
        let plan = try RoutePlan.make(mode: .global, rules: [])
        #expect(plan.mode == .global)
        #expect(plan.ipv4Included.map(\.cidr) == ["0.0.0.0/0"])
        #expect(plan.ipv6Included.map(\.cidr) == ["::/0"])
        #expect(plan.ipv4Excluded.isEmpty)
        #expect(plan.ipv6Excluded.isEmpty)
        #expect(plan.usesTunnelDNS)
    }

    @Test func directPlanCapturesNothing() throws {
        let plan = try RoutePlan.make(mode: .direct, rules: [])
        #expect(plan.mode == .direct)
        #expect(plan.ipv4Included.isEmpty)
        #expect(plan.ipv6Included.isEmpty)
        #expect(plan.ipv4Excluded.isEmpty)
        #expect(plan.ipv6Excluded.isEmpty)
        #expect(!plan.usesTunnelDNS)
    }

    @Test func rulePlanDefaultsToProxyWithoutRules() throws {
        let plan = try RoutePlan.make(mode: .rule, rules: [])
        #expect(plan.mode == .rule)
        #expect(plan.ipv4Included.map(\.cidr) == ["0.0.0.0/0"])
        #expect(plan.usesTunnelDNS)
    }

    @Test func rulePlanExcludesDirectPrefixesUnderProxyDefault() throws {
        let plan = try RoutePlan.make(mode: .rule, rules: [
            RoutingRule(kind: .ipv4, value: "10.0.0.0/8", policy: .direct),
            RoutingRule(kind: .match, value: nil, policy: .proxy),
        ])
        #expect(plan.mode == .rule)
        #expect(plan.ipv4Included.map(\.cidr) == ["0.0.0.0/0"])
        #expect(plan.ipv4Excluded.map(\.cidr) == ["10.0.0.0/8"])
        #expect(plan.usesTunnelDNS)
    }

    @Test func rulePlanIncludesOnlyProxyPrefixesUnderDirectDefault() throws {
        let plan = try RoutePlan.make(mode: .rule, rules: [
            RoutingRule(kind: .ipv4, value: "10.0.0.0/8", policy: .proxy),
            RoutingRule(kind: .ipv6, value: "fd66::/64", policy: .proxy),
            RoutingRule(kind: .match, value: nil, policy: .direct),
        ])
        #expect(plan.mode == .rule)
        #expect(plan.ipv4Included.map(\.cidr) == ["10.0.0.0/8"])
        #expect(plan.ipv6Included.map(\.cidr) == ["fd66::/64"])
        #expect(plan.ipv4Excluded.isEmpty)
        #expect(!plan.usesTunnelDNS)
    }

    @Test func rulesAreAppliedInFirstMatchOrder() throws {
        let plan = try RoutePlan.make(mode: .rule, rules: [
            RoutingRule(kind: .ipv4, value: "10.0.0.0/8", policy: .proxy),
            RoutingRule(kind: .ipv4, value: "10.0.0.0/16", policy: .direct),
            RoutingRule(kind: .match, value: nil, policy: .direct),
        ])
        // The earlier PROXY rule owns 10.0.0.0/16, so the later DIRECT rule cannot claim it.
        #expect(plan.ipv4Included.map(\.cidr) == ["10.0.0.0/8"])
    }

    @Test func overlappingDirectPrefixIsSubtractedFromLaterProxyRule() throws {
        let plan = try RoutePlan.make(mode: .rule, rules: [
            RoutingRule(kind: .ipv4, value: "10.0.0.0/16", policy: .direct),
            RoutingRule(kind: .ipv4, value: "10.0.0.0/8", policy: .proxy),
            RoutingRule(kind: .match, value: nil, policy: .direct),
        ])
        #expect(plan.ipv4Included.count == 8)
        #expect(!plan.ipv4Included.contains { $0.cidr == "10.0.0.0/16" })
        #expect(plan.ipv4Included.allSatisfy { $0.cidr.hasPrefix("10.") })
    }

    @Test func allDirectRulesCollapseToDirectMode() throws {
        let plan = try RoutePlan.make(mode: .rule, rules: [
            RoutingRule(kind: .ipv4, value: "10.0.0.0/8", policy: .direct),
            RoutingRule(kind: .match, value: nil, policy: .direct),
        ])
        #expect(plan.mode == .direct)
        #expect(plan.ipv4Included.isEmpty)
        #expect(!plan.usesTunnelDNS)
    }

    @Test func normalizesHostBitsInCIDR() throws {
        let plan = try RoutePlan.make(mode: .rule, rules: [
            RoutingRule(kind: .ipv4, value: "10.1.2.3/8", policy: .proxy),
            RoutingRule(kind: .match, value: nil, policy: .direct),
        ])
        #expect(plan.ipv4Included.map(\.cidr) == ["10.0.0.0/8"])
    }

    @Test func rejectsTooManyRoutes() {
        let rules = (0..<129).map { index in
            RoutingRule(kind: .ipv4, value: "10.0.\(index).0/24", policy: .proxy)
        } + [RoutingRule(kind: .match, value: nil, policy: .direct)]
        let error = #expect(throws: PrototypeError.self) {
            try RoutePlan.make(mode: .rule, rules: rules)
        }
        #expect(error?.rawValue == PrototypeError.invalidRulePlan.rawValue)
    }
}
