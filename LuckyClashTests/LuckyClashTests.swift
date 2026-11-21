import Foundation
import Testing
@testable import LuckyClash

@MainActor
struct LuckyClashTests {
    @Test func acceptsIPv6EndpointAndUsesBothDefaultRoutes() throws {
        let configuration = try PrototypeConfiguration.decode(try testJSON())
        #expect(configuration.endpoint == "[2001:db8:1::30]:51820")
        let settings = try configuration.wireGuardSettings()
        #expect(settings.contains("\nallowed_ip=0.0.0.0/0\nallowed_ip=::/0\n"))
    }

    @Test(arguments: ["endpointAddress", "endpointPort", "clientIPv4", "clientIPv6", "dnsServers", "privateKey", "peerPublicKey"])
    func rejectsInvalidField(_ field: String) throws {
        let invalidValues: [String: Any] = [
            "endpointAddress": "test.example",
            "endpointPort": 0,
            "clientIPv4": "255.255.255.255",
            "clientIPv6": "fe80::1",
            "dnsServers": ["2001:0db8:1:0:0:0:0:30"],
            "privateKey": "wrong-length",
            "peerPublicKey": Data(repeating: 0, count: 32).base64EncodedString()
        ]
        let data = try testJSON(overrides: [field: invalidValues[field]!])
        let error = #expect(throws: PrototypeError.InvalidField.self) {
            try PrototypeConfiguration.decode(data)
        }
        #expect(error?.name == field)
    }

    private func testJSON(overrides: [String: Any] = [:]) throws -> Data {
        let values: [String: Any] = [
            "endpointAddress": "2001:db8:1::30",
            "endpointPort": 51820,
            "clientIPv4": "10.66.0.2",
            "clientIPv6": "fd66::2",
            "dnsServers": ["10.66.0.1", "fd66::1"],
            "privateKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "peerPublicKey": Data(repeating: 2, count: 32).base64EncodedString()
        ]
        return try JSONSerialization.data(withJSONObject: values.merging(overrides) { _, override in override })
    }
}
