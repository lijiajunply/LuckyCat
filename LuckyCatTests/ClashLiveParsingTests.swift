import Foundation
import Testing
@testable import LuckyCat

struct ClashLiveParsingTests {
    @Test func parsesConnectionSnapshot() throws {
        let json = """
        {"downloadTotal":1234,"uploadTotal":567,"memory":42,"connections":[{"id":"abc",\
        "metadata":{"network":"tcp","type":"HTTPS","sourceIP":"192.168.1.2",\
        "destinationIP":"142.250.72.14","sourcePort":"51234","destinationPort":"443",\
        "host":"www.youtube.com","dnsMode":"fake-ip","sniffHost":"www.youtube.com",\
        "destinationGeoIP":["US"],"remoteDestination":"142.250.72.14:443",\
        "processPath":"/Applications/Safari.app"},"upload":11,"download":22,\
        "start":"2026-11-21T08:30:00.123456789+08:00","chains":["LuckyCat","香港 01"],\
        "rule":"DomainSuffix","rulePayload":"youtube.com"}]}
        """
        let snapshot = try #require(ClashLiveParsing.snapshot(from: json))
        #expect(snapshot.downloadTotal == 1234)
        #expect(snapshot.uploadTotal == 567)
        #expect(snapshot.connections.count == 1)

        let connection = try #require(snapshot.connections.first)
        #expect(connection.id == "abc")
        #expect(connection.metadata.network == "tcp")
        #expect(connection.metadata.destinationPort == "443")
        #expect(connection.destinationWithPort == "www.youtube.com:443")
        #expect(connection.outboundName == "香港 01")
        #expect(connection.ruleSummary == "DomainSuffix youtube.com")
        #expect(connection.chains == ["LuckyCat", "香港 01"])
        #expect(connection.download == 22)
        #expect(connection.upload == 11)
        #expect(connection.start != nil)
        #expect(connection.metadata.destinationGeoIP == ["US"])
        #expect(!connection.isDirect)
    }

    @Test func toleratesNumericPortsAndBareArrays() throws {
        let json = """
        [{"id":"def","metadata":{"network":"udp","destinationIP":"119.29.29.29",\
        "destinationPort":53},"chains":["DIRECT"],"rule":"MATCH"}]
        """
        let snapshot = try #require(ClashLiveParsing.snapshot(from: json))
        let connection = try #require(snapshot.connections.first)
        #expect(connection.metadata.destinationPort == "53")
        #expect(connection.destinationName == "119.29.29.29")
        #expect(connection.isDirect)
    }

    @Test func parsesLogFrames() {
        let message = #"{"type":"warning","payload":"timeout when dialing node"}"#
        let logs = ClashLiveParsing.logs(from: message)
        #expect(logs.count == 1)
        #expect(logs.first?.level == .warning)
        #expect(logs.first?.payload == "timeout when dialing node")
    }

    @Test func parsesBatchedLogFrames() {
        let message = """
        [{"type":"info","payload":"[TCP] one"},{"level":"error","payload":"two"}]
        """
        let logs = ClashLiveParsing.logs(from: message)
        #expect(logs.count == 2)
        #expect(logs[0].level == .info)
        #expect(logs[0].tag == "TCP")
        #expect(logs[1].level == .error)
    }

    @Test func keepsPlainLogText() {
        let logs = ClashLiveParsing.logs(from: "plain core line")
        #expect(logs.first?.level == .info)
        #expect(logs.first?.payload == "plain core line")
    }

    @Test func parsesTrafficRates() throws {
        let rates = try #require(ClashLiveParsing.traffic(from: #"{"up":120,"down":3400}"#))
        #expect(rates.upload == 120)
        #expect(rates.download == 3400)
    }

    @Test func rejectsUnrelatedJSON() {
        #expect(ClashLiveParsing.snapshot(from: #"{"mode":"rule"}"#) == nil)
        #expect(ClashLiveParsing.traffic(from: "not json") == nil)
    }

    @Test @MainActor func stagesLegacyWireGuardJSON() {
        let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
        let publicKey = Data(repeating: 2, count: 32).base64EncodedString()
        let json = """
        {"endpointAddress":"192.0.2.40","endpointPort":51820,"clientIPv4":"10.66.0.2",\
        "clientIPv6":"fd66::2","dnsServers":["10.66.0.1"],"privateKey":"\(privateKey)",\
        "peerPublicKey":"\(publicKey)"}
        """
        let vpn = PrototypeVPN()
        vpn.stage(Data(json.utf8))
        #expect(vpn.hasStagedImport)
        #expect(!vpn.imported.isEmpty)
        #expect(vpn.importError == nil)
    }
}
