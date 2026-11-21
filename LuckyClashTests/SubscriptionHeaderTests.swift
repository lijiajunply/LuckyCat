import Foundation
import Testing
@testable import LuckyCat

@MainActor
struct SubscriptionHeaderTests {
    @Test func parsesUserInfoIntervalAndFileName() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = SubscriptionHeader.parse(headers: [
            "subscription-userinfo": "upload=1024; download=2048; total=4096; expire=1735689600",
            "profile-update-interval": "12",
            "content-disposition": "attachment; filename=\"airport.yaml\"",
            "profile-web-page-url": "https://example.com/user"
        ], now: now)

        #expect(metadata.subscription.upload == 1024)
        #expect(metadata.subscription.download == 2048)
        #expect(metadata.subscription.total == 4096)
        #expect(metadata.subscription.expire == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(metadata.subscription.updateIntervalHours == 12)
        #expect(metadata.subscription.webPageURL == "https://example.com/user")
        #expect(metadata.subscription.lastUpdated == now)
        #expect(metadata.suggestedName == "airport.yaml")
    }

    @Test func treatsLargeIntervalsAsMinutes() {
        let metadata = SubscriptionHeader.parse(headers: ["profile-update-interval": "1440"])
        #expect(metadata.subscription.updateIntervalHours == 24)
    }

    @Test func decodesBase64ProfileTitle() {
        let encoded = Data("My Airport".utf8).base64EncodedString()
        let metadata = SubscriptionHeader.parse(headers: ["profile-title": "base64:\(encoded)"])
        #expect(metadata.suggestedName == "My Airport")
    }

    @Test func toleratesMissingHeaders() {
        let metadata = SubscriptionHeader.parse(headers: [:])
        #expect(metadata.subscription.total == nil)
        #expect(metadata.subscription.updateIntervalHours == nil)
        #expect(metadata.suggestedName == nil)
        #expect(metadata.subscription.lastUpdated != nil)
    }
}
