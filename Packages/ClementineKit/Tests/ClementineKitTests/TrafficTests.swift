import Testing
@testable import ClementineKit

/// The app's traffic adds up across connections and streams.
struct TrafficTests {
    @Test func addsUp() {
        let before = Traffic.byteCounts
        Traffic.add(sent: 10, received: 300)
        let after = Traffic.byteCounts
        #expect(after.sent - before.sent >= 10)
        #expect(after.received - before.received >= 300)
    }
}
