import Foundation
import Testing
@testable import LuckyCat

@MainActor
struct ConfigurationImportTests {
    @Test func importsMultipleNodesAndValidatesTunnelSettings() throws {
        let data = Data(("proxies:\n" + node("one") + "\n" + node("two")).utf8)
        let document = try ConfigurationImport.parse(data)
        #expect(document.nodes.map(\.name) == ["one", "two"])
        #expect(document.nodes.first?.configuration.endpoint == "[2001:db8::40]:51820")
        #expect(document.nodes.first?.configuration.dnsServers == ["10.66.0.1", "fd66::1"])
        #expect(document.rules.isEmpty)
        #expect(document.warnings.isEmpty)
    }

    @Test func importsRulesBeforeProxies() throws {
        let source = "rules:\n"
            + "  - IP-CIDR,10.0.0.0/8,DIRECT\n"
            + "  - IP-CIDR6,fd66::/64,Proxy\n"
            + "  - MATCH,Proxy\n"
            + "proxies:\n" + node("one") + "\n" + node("two")
        let document = try ConfigurationImport.parse(Data(source.utf8))
        #expect(document.nodes.map(\.name) == ["one", "two"])
        #expect(document.rules.count == 3)
        #expect(document.rules[0].kind == .ipv4)
        #expect(document.rules[0].policy == .direct)
        #expect(document.rules[0].value == "10.0.0.0/8")
        #expect(document.rules[1].kind == .ipv6)
        #expect(document.rules[1].policy == .proxy)
        #expect(document.rules[2].kind == .match)
        #expect(document.rules[2].policy == .proxy)
        #expect(document.warnings.isEmpty)
    }

    @Test func importsRulesAfterProxiesAndIgnoresKnownSections() throws {
        let source = "mixed-port: 7890\n"
            + "proxy-groups:\n"
            + "  - name: Proxy\n"
            + "    type: select\n"
            + "proxies:\n" + node("one") + "\n"
            + "rules:\n  - MATCH,DIRECT"
        let document = try ConfigurationImport.parse(Data(source.utf8))
        #expect(document.nodes.count == 1)
        #expect(document.rules.count == 1)
        #expect(document.rules[0].policy == .direct)
        #expect(document.warnings.contains { $0.contains("mixed-port") })
        #expect(document.warnings.contains { $0.contains("proxy-groups") })
    }

    @Test func warnsAboutUnsupportedRules() throws {
        let source = "rules:\n"
            + "  - DOMAIN-SUFFIX,example.com,Proxy\n"
            + "  - IP-CIDR,10.0.0.0/8,REJECT\n"
            + "  - MATCH,Proxy\n"
            + "  - IP-CIDR,192.0.2.0/24,DIRECT\n"
            + "proxies:\n" + node("one")
        let document = try ConfigurationImport.parse(Data(source.utf8))
        #expect(document.rules.count == 1)
        #expect(document.warnings.contains { $0.contains("已忽略 2 条") })
        #expect(document.warnings.contains { $0.contains("MATCH 之后") })
    }

    @Test func warnsWhenRulesHaveNoMatch() throws {
        let source = "rules:\n  - IP-CIDR,10.0.0.0/8,DIRECT\nproxies:\n" + node("one")
        let document = try ConfigurationImport.parse(Data(source.utf8))
        #expect(document.rules.count == 1)
        #expect(document.warnings.contains { $0.contains("缺少 MATCH") })
    }

    @Test(arguments: [
        ("private-key:", "private-key: *alias #", "节点 1 · private-key"),
        ("dns: [10.66.0.1, 'fd66::1']", "dns: [10.66.0.1, [fd66::1]]", "节点 1 · dns"),
        ("type: wireguard", "type: ss", "节点 1 · type"),
        ("type: wireguard", "type: wireguard\n    type: wireguard", "第 4 行 · type"),
        ("udp: true", "rules: [DIRECT]", "第 11 行"),
    ])
    func rejectsUnsupportedInput(field: String, replacement: String, location: String) {
        let data = Data(("proxies:\n" + node("one").replacingOccurrences(of: field, with: replacement)).utf8)
        let error = #expect(throws: ConfigurationImport.Invalid.self) { try ConfigurationImport.parse(data) }
        #expect(error?.location == location)
    }

    @Test func rejectsInvalidRuleCIDR() {
        let source = "rules:\n  - IP-CIDR,10.0.0.0/99,DIRECT\nproxies:\n" + node("one")
        let error = #expect(throws: ConfigurationImport.Invalid.self) {
            try ConfigurationImport.parse(Data(source.utf8))
        }
        #expect(error?.location == "第 2 行 · 网段")
    }

    @Test func acceptsQuotedRuleEntry() throws {
        let source = "rules:\n  - \"IP-CIDR,10.0.0.0/8,DIRECT\"\nproxies:\n" + node("one")
        let document = try ConfigurationImport.parse(Data(source.utf8))
        #expect(document.rules.first?.kind == .ipv4)
        #expect(document.rules.first?.policy == .direct)
    }

    @Test func boundsSupportedRuleCount() {
        let rules = (0..<129).map { _ in "  - IP-CIDR,10.0.0.0/8,DIRECT" }.joined(separator: "\n")
        let error = #expect(throws: ConfigurationImport.Invalid.self) {
            try ConfigurationImport.parse(Data(("rules:\n" + rules + "\nproxies:\n" + node("one")).utf8))
        }
        #expect(error?.location == "规则数量上限 128")
    }

    @Test func boundsNodeCountAndInputSize() {
        let source = "proxies:\n" + (1...17).map { node("node-\($0)") }.joined(separator: "\n")
        let countError = #expect(throws: ConfigurationImport.Invalid.self) {
            try ConfigurationImport.parse(Data(source.utf8))
        }
        #expect(countError?.location == "节点数量上限 16")
        let sizeError = #expect(throws: ConfigurationImport.Invalid.self) {
            try ConfigurationImport.parse(Data(repeating: 32, count: ConfigurationImport.maximumFileSize + 1))
        }
        #expect(sizeError?.location == "文件大小上限 32 KB")
    }

    private func node(_ name: String) -> String {
        """
          - name: \(name)
            type: wireguard
            server: 2001:db8::40
            port: 51820
            ip: 10.66.0.2
            ipv6: "fd66::2"
            private-key: \(Data(repeating: 1, count: 32).base64EncodedString())
            public-key: \(Data(repeating: 2, count: 32).base64EncodedString())
            dns: [10.66.0.1, 'fd66::1']
            udp: true
        """
    }
}
