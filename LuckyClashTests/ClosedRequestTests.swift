import Foundation
import Testing
@testable import LuckyClash

struct ClosedRequestTests {
    @Test func resetRecordsOnlyPreviouslySeenConnectionsThatDisappeared() {
        let first = ClashConnection(id: "first"), second = ClashConnection(id: "second")
        let event = ClashConnectionEvent(type: "new", id: "first", connection: first,
                                         upload: nil, download: nil, closedAt: nil)
        let date = Date(timeIntervalSince1970: 100)
        let batch = ClashConnectionEventBatch(reset: true, events: [event])
        let missing = NetworkStore.ClosedRequest.missingAfterReset(batch, previous: ["first": first, "second": second], at: date)
        #expect(missing.count == 1)
        #expect(missing.first?.id == "second")
        #expect(missing.first?.closedAt == date)
        #expect(missing.first?.inferredAfterReconnect == true)
        #expect(NetworkStore.ClosedRequest.missingAfterReset(.init(reset: false, events: []), previous: ["first": first], at: date).isEmpty)
    }
    @Test func preservesMetadataAndFinalCounters() throws {
        var previous = ClashConnection(id: "one")
        previous.metadata.host = "example.com"
        previous.upload = 30
        previous.download = 40
        let event = ClashConnectionEvent(type: "closed", id: "one", connection: nil,
                                         upload: 90, download: 80, closedAt: Date(timeIntervalSince1970: 100))
        let request = try #require(NetworkStore.ClosedRequest.resolve(event, previous: previous, current: nil))
        #expect(request.connection.metadata.host == "example.com")
        #expect(request.connection.upload == 90)
        #expect(request.connection.download == 80)
        let fromSnapshot = try #require(NetworkStore.ClosedRequest.resolve(event, previous: nil, current: previous))
        #expect(fromSnapshot.connection.upload == 90)
        #expect(NetworkStore.ClosedRequest.resolve(event, previous: nil, current: nil) == nil)
    }
}
