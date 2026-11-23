import Foundation
import NetworkExtension
import Testing
@testable import LuckyClash

@MainActor
struct ProfileMetadataTests {
    @Test func decodesLegacyNodeWithoutMetadata() throws {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let json = """
        {
          "profiles": [
            {
              "id": "\(profileID.uuidString)",
              "name": "Legacy",
              "nodes": [
                { "id": "\(nodeID.uuidString)", "name": "Peer", "endpoint": "192.0.2.40:51820" }
              ],
              "selectedNodeID": "\(nodeID.uuidString)"
            }
          ],
          "selectedProfileID": "\(profileID.uuidString)"
        }
        """

        let library = try JSONDecoder().decode(ProfileLibrary.self, from: Data(json.utf8))
        let node = try #require(library.selectedProfile?.selectedNode)
        #expect(node.clientIPv4 == nil)
        #expect(node.dnsServers == nil)
        #expect(node.compatibilityNotes.count == 2)
        #expect(library.trafficMode == .rule)
        #expect(library.selectedProfile?.sourceURL == nil)
        #expect(library.selectedProfile?.rules == nil)
        #expect(library.selectedProfile?.selectedOutboundName == "Peer")
    }

    @Test func preservesSelectedNestedGroup() throws {
        let node = Profile.Node(id: UUID(), name: "Peer", endpoint: "example.com")
        let profile = Profile(id: UUID(), name: "Test", nodes: [node], selectedNodeID: node.id,
                              clashGroup: "选择", clashSelectedMember: "自动选择")
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.clashGroup == "选择")
        #expect(decoded.selectedOutboundName == "自动选择")
    }

    @Test func roundTripsSourceURLRulesAndMode() throws {
        let profileID = UUID()
        let profile = Profile(
            id: profileID, name: "Rules", nodes: [], selectedNodeID: UUID(),
            sourceURL: URL(string: "https://example.com/config.yaml"),
            rules: [RoutingRule(kind: .match, value: nil, policy: .proxy)]
        )
        var library = ProfileLibrary(profiles: [profile], selectedProfileID: profileID)
        library.mode = .rule

        let decoded = try JSONDecoder().decode(
            ProfileLibrary.self, from: JSONEncoder().encode(library)
        )
        #expect(decoded.trafficMode == .rule)
        #expect(decoded.profiles.first?.sourceURL == profile.sourceURL)
        #expect(decoded.profiles.first?.rules == profile.rules)
    }

    @Test func describesNodeCompatibility() throws {
        let node = Profile.Node(
            id: UUID(), name: "Peer", endpoint: "[fd66::1]:51820",
            clientIPv4: "10.66.0.2", clientIPv6: "fd66::2", dnsServers: ["10.66.0.1", "fd66::1"]
        )
        #expect(node.compatibilityNotes.contains { $0.contains("10.66.0.2 / fd66::2") })
        #expect(node.compatibilityNotes.contains { $0.contains("10.66.0.1, fd66::1") })
        #expect(node.compatibilityNotes.contains { $0.contains("普通网络") })
    }

    @Test func decodesExtensionReplyWithoutTraffic() throws {
        struct LegacyReply: Codable {
            let version: Int
            let id: UUID
            let ready: Bool
        }
        let id = UUID()
        let data = try JSONEncoder().encode(LegacyReply(version: TunnelStatusMessage.version, id: id, ready: true))
        let reply = try JSONDecoder().decode(TunnelStatusMessage.Reply.self, from: data)
        #expect(reply.id == id)
        #expect(reply.ready)
        #expect(reply.bytesIn == nil)
        #expect(reply.bytesOut == nil)
    }

    @Test func mapsErrorsToRecoveryHints() {
        #expect(PrototypeVPN.issue(for: PrototypeError.handshakeTimeout) == .remote)
        #expect(PrototypeVPN.issue(for: PrototypeError.missingConfiguration) == .configuration)
        #expect(PrototypeVPN.issue(for: PrototypeError.networkSettings) == .configuration)
        #expect(PrototypeVPN.issue(for: PrototypeError.keychainUnavailable) == .permission)
        #expect(PrototypeVPN.issue(for: PrototypeError.profileStorage) == .storage)
        #expect(PrototypeVPN.issue(for: PrototypeError.invalidRulePlan) == .configuration)
        #expect(PrototypeVPN.issue(for: CocoaError(.fileReadNoSuchFile)) == .storage)
        #expect(PrototypeVPN.issue(for: NSError(
            domain: NEVPNErrorDomain, code: NEVPNError.configurationReadWriteFailed.rawValue
        )) == .permission)
        #expect(PrototypeVPN.issue(for: NSError(
            domain: NEVPNErrorDomain, code: NEVPNError.connectionFailed.rawValue
        )) == .remote)
    }
}
