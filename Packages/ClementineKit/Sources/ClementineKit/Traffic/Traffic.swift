import Synchronization

/// Everything this app has sent and received: over every connection to Clementine, and audio
/// streamed from it.
public enum Traffic {
    private static let totals = Mutex((sent: 0, received: 0))

    /// Bytes sent and received so far, since the app started.
    public static var byteCounts: (sent: Int, received: Int) {
        totals.withLock { $0 }
    }

    public static func add(sent: Int = 0, received: Int = 0) {
        totals.withLock {
            $0.sent += sent
            $0.received += received
        }
    }
}
