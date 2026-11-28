import Testing
@testable import LuckyClash

struct ServiceAvailabilityTests {
    @Test func identifiesExplicitRegionRestrictions() {
        let openAI = ServiceAvailabilityProbe.interpret(
            .chatGPT, status: 403, body: #"{"error":"unsupported_country"}"#, latency: 40
        )
        let claude = ServiceAvailabilityProbe.interpret(
            .claude, status: 200, body: "loc=HK\n", latency: 20
        )
        let youtube = ServiceAvailabilityProbe.interpret(
            .youtube, status: 200,
            body: #"Premium is not available in your country {"countryCode":"SG"}"#, latency: 30
        )
        #expect(openAI.status == .restricted)
        #expect(claude.status == .restricted)
        #expect(claude.region == "HK")
        #expect(youtube.status == .restricted)
        #expect(youtube.region == "SG")
    }

    @Test func uncertainResponsesDoNotClaimUnlock() {
        let netflix = ServiceAvailabilityProbe.interpret(.netflix, status: 404, body: "", latency: 10)
        #expect(netflix.status == .unknown)
        #expect(netflix.region == nil)
        let google = ServiceAvailabilityProbe.interpret(.google, status: 204, body: "", latency: 12)
        #expect(google.status == .reachable)
        #expect(google.latency == 12)
    }
}
