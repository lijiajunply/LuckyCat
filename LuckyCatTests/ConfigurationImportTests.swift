import Foundation
import Testing
@testable import LuckyCat

@MainActor
struct ConfigurationImportTests {
    @Test func importsMultipleNodesAndValidatesTunnelSettings() throws {
        let data = Data(("proxies:\n" + node("one") + "\n" + node("two")).utf8)
        let nodes = try ConfigurationImport.parse(data)
        #expect(nodes.map(\.name) == ["one", "two"])
        #expect(nodes.first?.configuration.endpoint == "[2001:db8::40]:51820")
        #expect(nodes.first?.configuration.dnsServers == ["10.66.0.1", "fd66::1"])
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
