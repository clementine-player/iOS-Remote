import Testing
@testable import ClementineKit

/// The position moves smoothly between Clementine's reports, which come once a second.
struct PositionClockTests {
    let start = ContinuousClock.now

    func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start + .milliseconds(milliseconds)
    }

    func playing(from seconds: Int) -> PositionClock {
        var clock = PositionClock()
        clock.seek(to: seconds, at: at(0))
        clock.setPlaying(true, at: at(0))
        return clock
    }

    func near(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.001
    }

    @Test func movesBetweenReports() {
        let clock = playing(from: 10)
        #expect(near(clock.position(at: at(0)), 10))
        #expect(near(clock.position(at: at(250)), 10.25))
        #expect(near(clock.position(at: at(900)), 10.9))
    }

    @Test func keepsMovingEvenlyThroughReportsThatAgree() {
        var clock = playing(from: 10)
        // Clementine's timer runs a little late, and its rounding skips a second.
        clock.report(11, at: at(1050))
        clock.report(12, at: at(2100))
        clock.report(14, at: at(3600))
        #expect(near(clock.position(at: at(3600)), 13.6))
        #expect(near(clock.position(at: at(4000)), 14))
    }

    @Test func aReportPullsTheEstimateWithinItsRounding() {
        var clock = playing(from: 10)
        // The song really started half a second in.
        clock.report(12, at: at(1000))
        #expect(near(clock.position(at: at(1000)), 11.5))
        #expect(near(clock.position(at: at(1500)), 12))
    }

    @Test func aReportFarFromTheEstimateIsASeek() {
        var clock = playing(from: 10)
        clock.report(60, at: at(1000))
        #expect(near(clock.position(at: at(1000)), 60))
        #expect(near(clock.position(at: at(1500)), 60.5))
    }

    @Test func stopsWhenPaused() {
        var clock = playing(from: 10)
        clock.setPlaying(false, at: at(600))
        #expect(near(clock.position(at: at(5000)), 10.6))
        clock.setPlaying(true, at: at(5000))
        #expect(near(clock.position(at: at(5200)), 10.8))
    }

    @Test func waitsWhenReportsStop() {
        let clock = playing(from: 10)
        #expect(near(clock.position(at: at(30_000)), 12))
    }

    @Test func seeksExactly() {
        var clock = playing(from: 10)
        clock.seek(to: 42, at: at(500))
        #expect(near(clock.position(at: at(500)), 42))
    }
}
