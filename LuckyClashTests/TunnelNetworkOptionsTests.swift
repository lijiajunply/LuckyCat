import Testing
@testable import LuckyClash

struct TunnelNetworkOptionsTests {
    @Test func ssidLimitCountsUTF8Bytes() {
        #expect(!TunnelNetworkOptions.hasInvalidTrustedSSIDs("家庭 Wi-Fi\n" + String(repeating: "a", count: 32)))
        #expect(TunnelNetworkOptions.hasInvalidTrustedSSIDs(String(repeating: "a", count: 33)))
        #expect(TunnelNetworkOptions.hasInvalidTrustedSSIDs(String(repeating: "中", count: 11)))
        #expect(!TunnelNetworkOptions.hasInvalidTrustedSSIDs("\n"))
    }
}
