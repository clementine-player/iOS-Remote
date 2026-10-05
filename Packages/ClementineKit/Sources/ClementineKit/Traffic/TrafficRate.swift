/// How fast data has moved lately: bytes a second over the last [window], from running totals
/// read now and then. Unlike the average since connecting, it falls to nothing soon after traffic
/// stops.
public struct TrafficRate: Sendable {
    private let window: Duration
    private var samples: [(time: ContinuousClock.Instant, bytes: Int)] = []

    public init(window: Duration = .seconds(5)) {
        self.window = window
    }

    /// Adds the running total [bytes] read at [time], and returns the rate since the oldest reading
    /// in the window; nil until there are two readings to compare.
    public mutating func add(_ bytes: Int, at time: ContinuousClock.Instant = .now) -> Int? {
        samples.append((time, bytes))
        // Keep one reading at or beyond the window's start, so the rate spans the whole window.
        while samples.count > 2, time - samples[1].time >= window {
            samples.removeFirst()
        }
        let oldest = samples[0]
        let elapsed = (time - oldest.time) / .milliseconds(1)
        guard elapsed > 0 else { return nil }
        return Int(Double(max(0, bytes - oldest.bytes)) * 1000 / elapsed)
    }
}
