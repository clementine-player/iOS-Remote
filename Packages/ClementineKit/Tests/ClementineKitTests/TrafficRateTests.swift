import Testing
@testable import ClementineKit

/// The traffic rate is over the last few seconds, so it falls soon after traffic stops.
struct TrafficRateTests {
    let start = ContinuousClock.now

    func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    @Test func needsTwoReadings() {
        var rate = TrafficRate()
        #expect(rate.add(1_000, at: at(0)) == nil)
    }

    @Test func isTheRateOverTheWindow() {
        var rate = TrafficRate(window: .seconds(5))
        var last: Int?
        // 100 KB a second for 10 seconds, read twice a second.
        for i in 0...20 {
            last = rate.add(i * 50_000, at: at(i * 500))
        }
        #expect(last == 100_000)
    }

    @Test func fallsToNothingOnceTrafficStops() {
        var rate = TrafficRate(window: .seconds(5))
        // A minute of streaming at 100 KB a second, then nothing.
        for i in 0...120 {
            _ = rate.add(i * 50_000, at: at(i * 500))
        }
        let total = 120 * 50_000

        #expect(rate.add(total, at: at(62_500)) == 50_000)
        var last: Int?
        for i in 126...130 {
            last = rate.add(total, at: at(i * 500))
        }
        #expect(last == 0)
    }
}
