import Foundation
import Testing
@testable import LuckyCat

struct QRCodePayloadTests {
    @Test func extractsSubscriptionFromDeepLink() {
        let url = QRCodePayload.subscriptionURL(
            from: "clash://install-config?url=https%3A%2F%2Fexample.com%2Fconfig.yaml"
        )
        #expect(url?.absoluteString == "https://example.com/config.yaml")
    }

    @Test func extractsSubscriptionFromPlainLink() {
        let url = QRCodePayload.subscriptionURL(from: "example.com/config.yaml")
        #expect(url?.absoluteString == "https://example.com/config.yaml")
    }

    @Test func rejectsInsecureLinks() {
        #expect(QRCodePayload.subscriptionURL(from: "http://example.com/config.yaml") == nil)
        #expect(QRCodePayload.subscriptionURL(from: "") == nil)
    }

    @Test func rejectsUnreadablePayloads() {
        #expect(QRCodePayload.subscriptionURL(from: "not a link") == nil)
    }
}
