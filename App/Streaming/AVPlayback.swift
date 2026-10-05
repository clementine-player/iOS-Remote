import AVFoundation
import ClementineKit

/// [Playback] with AVQueuePlayer, which plays a queued item straight after the current one and
/// fetches with Range requests. It plays as music: in the background, and on AirPlay or Bluetooth
/// like any other. iOS pauses it for calls, which the [Renderer] tells Clementine.
@MainActor
final class AVPlayback: Playback {
    weak var listener: PlaybackListener?

    private var player: AVQueuePlayer?
    private var volume: Float = 1
    /// What's playing, and what's queued to follow it. Kept here rather than read from the
    /// player, which may have moved on by the time it says an item ended.
    private var current: AVPlayerItem?
    private var queued: AVPlayerItem?
    /// KVO can call back on any thread: its handlers are @Sendable and hop to the main actor.
    private var playerObservation: NSKeyValueObservation?
    /// Per item: its status, and the notifications of its end.
    private var itemObservations: [ObjectIdentifier: [Any]] = [:]
    /// Per item: the bytes it has fetched that are already counted in [Traffic].
    private var counted: [ObjectIdentifier: Int] = [:]
    /// Counts what's being fetched while there's a player.
    private var trafficTimer: Timer?

    var state: PlaybackState {
        guard let player, let current else { return .idle }
        switch player.timeControlStatus {
        case .playing:
            return .playing
        case .waitingToPlayAtSpecifiedRate:
            return .buffering
        case .paused:
            // Paused before it's ready: still loading.
            return current.status == .readyToPlay ? .paused : .buffering
        @unknown default:
            return .paused
        }
    }

    var positionMs: Int64 {
        guard let time = current?.currentTime(), time.isNumeric else { return 0 }
        return Int64(time.seconds * 1000)
    }

    var bufferedPercent: Int {
        guard let current, current.duration.isNumeric, current.duration.seconds > 0 else { return 0 }
        let loaded = current.loadedTimeRanges.map(\.timeRangeValue.end.seconds).max() ?? 0
        return Int(max(0, min(100, loaded / current.duration.seconds * 100)))
    }

    func load(_ source: PlaybackSource, startMs: Int64, playing: Bool) {
        activateSession()
        let player = makePlayer()
        clear()
        let item = makeItem(source)
        current = item
        player.insert(item, after: nil)
        if startMs > 0 {
            item.seek(to: CMTime(value: startMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero,
                      completionHandler: nil)
        }
        player.volume = volume
        if playing {
            player.play()
        } else {
            player.pause()
        }
        listener?.playbackStateChanged()
    }

    func queue(_ source: PlaybackSource?) {
        guard let player, let current else { return }
        // Only what's playing stays; anything queued after it is replaced.
        if let queued {
            forget(queued)
            player.remove(queued)
            self.queued = nil
        }
        if let source {
            let item = makeItem(source)
            queued = item
            player.insert(item, after: current)
        }
    }

    func play() {
        activateSession()
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seek(toMs positionMs: Int64) {
        current?.seek(to: CMTime(value: positionMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero,
                      completionHandler: nil)
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        player?.volume = volume
    }

    func stop() {
        guard let player else { return }
        player.pause()
        clear()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        listener?.playbackStateChanged()
    }

    // MARK: Player

    private func makePlayer() -> AVQueuePlayer {
        if let player {
            return player
        }
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        playerObservation = player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.listener?.playbackStateChanged() }
        }
        self.player = player
        // Twice a second, as the connection sheet reads it.
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countTraffic() }
        }
        return player
    }

    private func countTraffic() {
        for item in [current, queued].compactMap({ $0 }) {
            count(item)
        }
    }

    /// Adds what [item] has fetched since it was last counted to the app's [Traffic].
    private func count(_ item: AVPlayerItem) {
        let id = ObjectIdentifier(item)
        let fetched = item.accessLog()?.events.reduce(0) { $0 + max(0, Int($1.numberOfBytesTransferred)) } ?? 0
        let new = fetched - counted[id, default: 0]
        guard new > 0 else { return }
        Traffic.add(received: new)
        counted[id] = fetched
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
    }

    private func makeItem(_ source: PlaybackSource) -> AVPlayerItem {
        // Clementine's URLs have no extension: the type it gives says what the audio is.
        var options: [String: Any] = [:]
        if !source.mimeType.isEmpty {
            options[AVURLAssetOverrideMIMETypeKey] = source.mimeType
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: source.url, options: options))
        watch(item)
        return item
    }

    /// Removes what's playing and queued.
    private func clear() {
        for item in [current, queued].compactMap({ $0 }) {
            forget(item)
        }
        current = nil
        queued = nil
        player?.removeAllItems()
    }

    private func watch(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        let id = ObjectIdentifier(item)
        itemObservations[id] = [
            item.observe(\.status) { @Sendable [weak self] item, _ in
                let failure = item.status == .failed ? AVPlayback.describe(item.error) : nil
                Task { @MainActor in
                    self?.listener?.playbackStateChanged()
                    if let failure {
                        self?.failed(id, message: failure.message, transient: failure.transient)
                    }
                }
            },
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended(id) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] notification in
                // Stopping partway through is the network's doing: worth loading again.
                let message = AVPlayback.describe(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error).message
                MainActor.assumeIsolated { self?.failed(id, message: message, transient: true) }
            },
        ]
    }

    private func forget(_ item: AVPlayerItem) {
        count(item)
        counted[ObjectIdentifier(item)] = nil
        for observation in itemObservations.removeValue(forKey: ObjectIdentifier(item)) ?? [] {
            if let observation = observation as? NSKeyValueObservation {
                observation.invalidate()
            } else {
                NotificationCenter.default.removeObserver(observation)
            }
        }
    }

    /// Item [id] played to its end: the queued item follows, if there's one.
    private func ended(_ id: ObjectIdentifier) {
        guard let ended = current, ObjectIdentifier(ended) == id else { return }
        forget(ended)
        current = queued
        queued = nil
        if current != nil {
            listener?.playbackAdvanced()
        } else {
            listener?.playbackEnded()
        }
    }

    private func failed(_ id: ObjectIdentifier, message: String, transient: Bool) {
        // Only the item playing matters: a queued one is loaded again if Clementine sends it.
        guard let current, ObjectIdentifier(current) == id else { return }
        listener?.playbackFailed(message, transient: transient)
    }

    /// What went wrong, and whether it's the network's doing, worth trying again.
    private nonisolated static func describe(_ error: Error?) -> (message: String, transient: Bool) {
        guard let error = error as NSError? else { return ("Playback failed", false) }
        let network = error.domain == NSURLErrorDomain && [
            NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
        ].contains(error.code)
        return (error.localizedDescription, network)
    }
}
