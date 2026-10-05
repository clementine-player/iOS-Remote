import Foundation

extension Pb_Remote_ResponseDisconnect {
    /// How long until Clementine checks an auth code from this phone again, if it said.
    var retryAfter: Duration? {
        hasRetryAfterSeconds ? .seconds(retryAfterSeconds) : nil
    }
}

extension Duration {
    /// How long Clementine said to wait, for people: in seconds under a minute, and otherwise
    /// rounded up to whole minutes or hours, so it's never over before it's said. "10 seconds",
    /// "3 minutes", "1 hour".
    public func waitDescription(locale: Locale = .autoupdatingCurrent) -> String {
        var seconds = components.seconds
        if seconds >= 60 {
            seconds = (seconds + 59) / 60 * 60
        }
        if seconds > 60 * 60 {
            seconds = (seconds + 60 * 60 - 1) / (60 * 60) * (60 * 60)
        }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1).locale(locale))
    }
}
