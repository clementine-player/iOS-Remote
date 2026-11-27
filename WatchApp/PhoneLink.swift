import ClementineWatch
import Foundation
import Observation
import WatchConnectivity

/// The watch's way to Clementine: through Clementine Remote on the paired iPhone, which tells it
/// what's playing and carries out its commands. watchOS doesn't let the watch connect to
/// Clementine itself.
@MainActor
@Observable
final class PhoneLink: NSObject {
    /// How often to ask the phone for news while on screen, which keeps it connected.
    private static let refreshInterval = Duration.seconds(15)

    /// What the phone said last; nil until it has said anything.
    private(set) var nowPlaying: WatchNowPlaying?
    /// Whether the phone couldn't be reached last time.
    private(set) var isPhoneUnreachable = false
    /// Whether the phone tried to connect when asked, and couldn't.
    private(set) var couldNotConnect = false
    private var isAskingToConnect = false
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    override init() {
        super.init()
        #if DEBUG
        // For the App Store's screenshots (WatchUITests): what to show, without a phone.
        if let showcase = ProcessInfo.processInfo.environment["SHOWCASE_NOW_PLAYING"] {
            nowPlaying = WatchLinkCoding.decodeState(Data(showcase.utf8))
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the phone for news now, and every so often while the app's on screen.
    func startRefreshing() {
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                self?.send(.refresh)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stopRefreshing() {
        refreshing?.cancel()
        refreshing = nil
    }

    /// Asks the phone to connect to the Clementine it connected to last.
    func connect() {
        isAskingToConnect = true
        couldNotConnect = false
        nowPlaying?.connection = .connecting
        send(.refresh)
    }

    /// Sends [command] to the phone, showing what it does at once.
    func send(_ command: WatchCommand) {
        switch command {
        case .playPause:
            if let state = nowPlaying {
                nowPlaying?.position = state.position(at: .now)
                nowPlaying?.positionDate = .now
                nowPlaying?.isPlaying.toggle()
            }
        case .love:
            nowPlaying?.isLoved = true
        case .setVolume(let volume):
            nowPlaying?.volume = volume
        case .previous, .next, .refresh:
            break
        }
        let session = WCSession.default
        // Until activated, it can't send; it asks for news once it is.
        guard session.activationState == .activated else { return }
        guard session.isReachable else {
            isPhoneUnreachable = true
            return
        }
        // WatchConnectivity calls these on its own queue.
        session.sendMessageData(WatchLinkCoding.encode(command)) { @Sendable [weak self] reply in
            Task { @MainActor in self?.received(reply) }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor in self?.isPhoneUnreachable = true }
        }
    }

    // Replies to sendMessageData arrive as Data (with base64 cover in JSON), whereas application
    // context and push messages arrive as dictionaries with a separate raw cover Data key.
    private func received(_ data: Data?) {
        guard let state = WatchLinkCoding.decodeState(data) else { return }
        apply(state)
    }

    private func received(_ dictionary: [String: Any]) {
        guard let state = WatchLinkCoding.decodeState(dictionary) else { return }
        apply(state)
    }

    private func apply(_ state: WatchNowPlaying) {
        isPhoneUnreachable = false
        if isAskingToConnect, state.connection != .connecting {
            isAskingToConnect = false
            couldNotConnect = state.connection == .disconnected
        }
        nowPlaying = state
    }

    private func reachabilityChanged() {
        isPhoneUnreachable = !WCSession.default.isReachable
        if !isPhoneUnreachable, refreshing != nil {
            send(.refresh)
        }
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?
    ) {
        let context = SendableDictionary(session.receivedApplicationContext)
        Task { @MainActor in
            self.received(context.value)
            self.reachabilityChanged()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let wrapped = SendableDictionary(context)
        Task { @MainActor in self.received(wrapped.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let wrapped = SendableDictionary(message)
        Task { @MainActor in self.received(wrapped.value) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.reachabilityChanged() }
    }
}

/// Transfers non-Sendable WatchConnectivity dictionaries across to @MainActor without stripping
/// the separate cover Data key.
private struct SendableDictionary: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
