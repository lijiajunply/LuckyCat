import Foundation
import Testing
@testable import LuckyClash

@MainActor
struct ClashImportTests {
    @Test func keepsFullClashConfiguration() throws {
        let yaml = """
        mode: rule
        proxies:
          - name: One
            type: ss
            server: 192.0.2.10
            port: 8388
            cipher: aes-256-gcm
            password: secret
          - name: Two
            type: vmess
            server: 192.0.2.11
            port: 443
            uuid: 11111111-1111-1111-1111-111111111111
            alterId: 0
            cipher: auto
        proxy-groups:
          - name: Proxy
            type: select
            proxies: [One, Two]
        rules:
          - MATCH,Proxy
        """
        let document = try ClashImport.parse(Data(yaml.utf8))
        #expect(document.engine == .clash)
        #expect(document.nodes.map(\.name) == ["One", "Two"])
        #expect(document.nodes.first?.type == "ss")
        #expect(document.nodes.first?.endpoint == "192.0.2.10:8388")
        #expect(document.groups.first?.name == "Proxy")
        #expect(document.clashYAML?.contains("MATCH,Proxy") == true)
        #expect(document.warnings.isEmpty)
    }

    @Test func wrapsBareProxyListWithAGeneratedGroup() throws {
        let yaml = """
        proxies:
          - name: Only
            type: ss
            server: 192.0.2.12
            port: 8388
            cipher: aes-256-gcm
            password: secret
        """
        let document = try ClashImport.parse(Data(yaml.utf8))
        #expect(document.nodes.map(\.name) == ["Only"])
        #expect(document.groups.first?.name == "LuckyClash")
        let output = try #require(document.clashYAML)
        #expect(output.contains("proxy-groups"))
        #expect(output.contains("MATCH,LuckyClash"))
        #expect(output.contains("dns"))
    }

    @Test func capturesURLTestEndpointFromGroup() throws {
        let yaml = """
        proxies:
          - name: One
            type: ss
            server: 192.0.2.14
            port: 8388
            cipher: aes-256-gcm
            password: secret
        proxy-groups:
          - name: Auto
            type: url-test
            url: https://example.com/generate_204
            proxies: [One]
        rules:
          - MATCH,Auto
        """
        let document = try ClashImport.parse(Data(yaml.utf8))
        #expect(document.groups.first?.testURL == "https://example.com/generate_204")
    }

    @Test func convertsBase64ShareLinkSubscription() throws {
        let link = "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@192.0.2.13:8388#Node%20A"
        let payload = Data(link.utf8).base64EncodedData()
        let document = try ClashImport.parse(payload)
        #expect(document.engine == .clash)
        #expect(document.nodes.count == 1)
        #expect(document.nodes.first?.type == "ss")
        #expect(document.clashYAML?.contains("proxy-groups") == true)
    }

    @Test func decodesBase64WrappedConfiguration() throws {
        let yaml = """
        proxies:
          - name: Wrapped
            type: ss
            server: 192.0.2.20
            port: 8388
            cipher: aes-256-gcm
            password: secret
        rules:
          - MATCH,Wrapped
        """
        let document = try ClashImport.parse(Data(yaml.utf8).base64EncodedData())
        #expect(document.nodes.map(\.name) == ["Wrapped"])
        #expect(document.clashYAML?.contains("MATCH,Wrapped") == true)
    }

    @Test func convertsCommonShareLinkProtocols() throws {
        let links = [
            "vless://11111111-1111-1111-1111-111111111111@192.0.2.15:443?encryption=none&security=tls&type=ws&host=example.com&path=%2F#VL",
            "trojan://secret@192.0.2.16:443?sni=example.com#TR",
            "hysteria2://secret@192.0.2.17:443?sni=example.com#HY",
            "tuic://11111111-1111-1111-1111-111111111111:secret@192.0.2.18:443?congestion_control=bbr&alpn=h3#TU"
        ].joined(separator: "\n")
        let document = try ClashImport.parse(Data(links.utf8))
        #expect(document.nodes.count >= 3)
        #expect(document.clashYAML?.contains("proxy-groups") == true)
    }

    @Test func selectsDatGeodataForGeoRules() throws {
        let yaml = """
        proxies:
          - name: One
            type: ss
            server: 192.0.2.19
            port: 8388
            cipher: aes-256-gcm
            password: secret
        rules:
          - GEOIP,CN,DIRECT
          - MATCH,One
        """
        let document = try ClashImport.parse(Data(yaml.utf8))
        let output = try #require(document.clashYAML)
        #expect(output.replacingOccurrences(of: " ", with: "").contains("geodata-mode:true"))
        #expect(ClashGeodata.isRequired(output))
        #expect(!ClashGeodata.isRequired("rules:\n  - MATCH,DIRECT"))
    }

    @Test func convertsLegacyWireGuardConfiguration() throws {
        let configuration = try PrototypeConfiguration(
            endpointAddress: "192.0.2.40", endpointPort: 51820,
            clientIPv4: "10.77.0.2", clientIPv6: "fd00:77::2",
            dnsServers: ["10.77.0.1"],
            privateKey: Data(repeating: 1, count: 32).base64EncodedString(),
            peerPublicKey: Data(repeating: 2, count: 32).base64EncodedString()
        )
        try configuration.validate()
        let legacy = ImportedConfiguration(
            engine: .wireGuard,
            nodes: [ImportedNode(
                name: "Peer", endpoint: configuration.endpoint,
                configuration: configuration
            )],
            rules: [],
            warnings: []
        )
        let converted = try ClashImport.fromLegacy(legacy)
        #expect(converted.engine == .clash)
        #expect(converted.nodes.first?.type == "wireguard")
        #expect(converted.groups.first?.name == "LuckyClash")
        let yaml = try #require(converted.clashYAML)
        #expect(yaml.contains("type: wireguard"))
        #expect(yaml.contains("private-key"))
        #expect(yaml.contains("MATCH,LuckyClash"))
        #expect(!ClashGeodata.isRequired(yaml))
    }

    @Test func rejectsUnreadablePayload() {
        let error = #expect(throws: ClashImport.Failure.self) {
            try ClashImport.parse(Data("this is not a configuration".utf8))
        }
        #expect(error != nil)
    }

    @Test func rejectsOversizedPayload() {
        let data = Data(repeating: 0x20, count: ClashImport.maximumBytes + 1)
        let error = #expect(throws: ClashImport.Failure.self) {
            try ClashImport.parse(data)
        }
        #expect(error == .tooLarge)
    }
}
