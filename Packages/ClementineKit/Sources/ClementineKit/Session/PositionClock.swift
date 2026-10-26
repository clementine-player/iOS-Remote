/// Estimates the song's position between Clementine's reports of it, so it can move smoothly.
///
/// While playing, Clementine reports the position once a second, rounded to whole seconds, and
/// while paused not at all. Between reports the position moves with this phone's clock. Each
/// report pulls it back within the half second the rounding allows, and one far from it
/// (Clementine seeked) moves it there.
public struct PositionClock: Sendable {
    /// Clementine rounds the position to the nearest second.
    private static let rounding = 0.5
    /// How late a report can arrive, and still only correct the estimate.
    private static let latency = 0.25
    /// Further than this from the estimate, a report is a seek.
    private static let jump = 1.5
    /// Reports come every second; without one for longer, the position waits for the next.
    private static let maxUnreported = 2.0

    private var anchor = 0.0
    private var anchorTime = ContinuousClock.now
    private var playing = false

    public init() {}

    /// The position at `now`, in seconds.
    public func position(at now: ContinuousClock.Instant = .now) -> Double {
        guard playing else { return anchor }
        let elapsed = (now - anchorTime) / .seconds(1)
        // If Clementine's reports stop coming, the position stops soon after, rather than run on.
        return anchor + min(max(elapsed, 0), Self.maxUnreported)
    }

    /// Clementine reported the position, in whole seconds.
    public mutating func report(_ seconds: Int, at now: ContinuousClock.Instant = .now) {
        let estimate = position(at: now)
        let reported = Double(seconds)
        anchor = abs(estimate - reported) > Self.jump
            ? reported
            : min(max(estimate, reported - Self.rounding), reported + Self.rounding + Self.latency)
        anchorTime = now
    }

    /// Clementine started or stopped playing.
    public mutating func setPlaying(_ playing: Bool, at now: ContinuousClock.Instant = .now) {
        guard playing != self.playing else { return }
        anchor = position(at: now)
        anchorTime = now
        self.playing = playing
    }

    /// The position is now exactly `seconds`: a new song started, or the user seeked.
    public mutating func seek(to seconds: Int, at now: ContinuousClock.Instant = .now) {
        anchor = Double(seconds)
        anchorTime = now
    }
}
