import ClementineKit
import ClementineWatch
import UIKit
import WatchConnectivity

/// The Apple Watch app's way to Clementine. watchOS doesn't let the watch open a connection to
/// Clementine itself, so the phone tells it what's playing and carries out its commands.
///
/// A command from the watch wakes the app in the background if need be. The app then connects
/// (again), and keeps the connection for as long as the watch keeps asking, and iOS allows.
@MainActor
final class WatchLink: NSObject {
    /// How long the connection stays up in the background after the watch last asked for anything.
    private static let holdTime = Duration.seconds(30)
    /// The cover's size on the watch, in pixels: about the screen's, as it fills it, but small
    /// enough to send.
    private static let coverSize: CGFloat = 320

    private unowned let model: AppModel
    private var sent: WatchNowPlaying?
    private var coverSource: Data?
    private var cover: Data?
    private var release: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(model: AppModel) {
        self.model = model
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        observe()
    }

    // MARK: Telling the watch

    /// Sends what's playing whenever it changes.
    private func observe() {
        withObservationTracking {
            _ = nowPlaying()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func nowPlaying() -> WatchNowPlaying {
        let session = model.session
        let connection: WatchNowPlaying.Connection = switch session.status {
        case .connected, .reconnecting, .suspended: .connected
        case .connecting, .downloadingData: .connecting
        case .disconnected: .disconnected
        }
        let hostName = session.endpoint != nil ? session.hostName : lastHostName
        guard connection == .connected, let song = session.song else {
            return WatchNowPlaying(connection: connection, hostName: hostName, volume: session.volume)
        }
        return WatchNowPlaying(
            connection: connection, hostName: hostName, title: song.title, artist: song.artist, album: song.album,
            isPlaying: session.playState == .playing, volume: session.volume, length: song.length,
            position: session.position, showsLove: model.settings.showLastFM, isLoved: session.isLoved,
            cover: smallCover(song.artData))
    }

    /// The Clementine connected to last, by name if it was picked from the network.
    private var lastHostName: String {
        let name = model.settings.lastServerName
        return name.isEmpty ? model.settings.lastHost : name
    }

    /// The cover, made small enough to send.
    private func smallCover(_ data: Data?) -> Data? {
        guard data != coverSource else { return cover }
        coverSource = data
        cover = data.flatMap(UIImage.init(data:)).flatMap { image in
            let side = Self.coverSize
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                // Fill the square, cropping a cover that isn't.
                let scale = max(side / image.size.width, side / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(
                    x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            }
            return scaled.jpegData(compressionQuality: 0.6)
        }
        return cover
    }

    private func update(force: Bool = false) {
        let state = nowPlaying()
        guard force || sent.map(state.differs) ?? true else { return }
        send(state)
    }

    private func send(_ state: WatchNowPlaying) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        sent = state
        let message = WatchLinkCoding.encode(state)
        // The context reaches the watch app next time it runs; a message reaches it now, if it's
        // running.
        try? session.updateApplicationContext(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil)
        }
    }

    // MARK: Doing what the watch asks

    /// Carries out [command], and returns what's playing then.
    private func perform(_ command: WatchCommand) async -> WatchNowPlaying {
        holdConnection()
        guard await connect() else {
            update(force: true)
            return nowPlaying()
        }
        let session = model.session
        switch command {
        case .playPause: session.playPause()
        case .previous: session.previous()
        case .next: session.next()
        case .love: session.love()
        case .setVolume(let volume): session.setVolume(volume)
        case .refresh: update(force: true)
        }
        if command != .refresh {
            // Long enough for Clementine to say what changed, in time for the reply.
            try? await Task.sleep(for: .milliseconds(300))
        }
        let state = nowPlaying()
        sent = state
        return state
    }

    /// Connects to Clementine if the app isn't connected, and waits until it is; false if it can't.
    private func connect() async -> Bool {
        let session = model.session
        switch session.status {
        case .connected:
            return true
        case .suspended:
            session.resume()
        case .disconnected:
            guard !model.settings.lastHost.isEmpty else { return false }
            let name = model.settings.lastServerName
            model.connect(host: model.settings.lastHost, name: name.isEmpty ? nil : name)
        case .connecting, .downloadingData, .reconnecting:
            break
        }
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            switch session.status {
            case .connected: return true
            case .disconnected: return false
            default: continue
            }
        }
        return false
    }

    /// In the background, keeps the connection a while longer, then lets it go as the app does
    /// when sent to the background.
    private func holdConnection() {
        release?.cancel()
        guard UIApplication.shared.applicationState == .background else {
            endBackgroundTask()
            return
        }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Apple Watch") { [weak self] in
                MainActor.assumeIsolated { self?.letGo() }
            }
        }
        release = Task { [weak self] in
            try? await Task.sleep(for: Self.holdTime)
            guard !Task.isCancelled else { return }
            self?.letGo()
        }
    }

    private func letGo() {
        release?.cancel()
        if UIApplication.shared.applicationState == .background, !model.session.isPlayingHere {
            model.session.suspend()
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?
    ) {
        Task { @MainActor in self.update(force: true) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switched to another watch: talk to that one.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.update(force: true) }
    }

    /// The watch's commands. The reply says what's playing then, so the watch hears it even when
    /// the phone can't reach it otherwise.
    nonisolated func session(
        _ session: WCSession, didReceiveMessageData data: Data, replyHandler: @escaping (Data) -> Void
    ) {
        guard let command = WatchLinkCoding.decodeCommand(data) else {
            replyHandler(Data())
            return
        }
        let reply = UncheckedSendable(replyHandler)
        Task { @MainActor in
            let state = await self.perform(command)
            reply.value(WatchLinkCoding.encodeData(state))
        }
    }
}

/// WatchConnectivity's reply handlers can be called from any thread, but aren't marked Sendable.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
