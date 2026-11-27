import AVFoundation
import ClementineKit

/// [Playback] with AVQueuePlayer, which plays a queued item straight after the current one and
/// fetches with Range requests. It plays as music: in the background, and on AirPlay or Bluetooth
/// like any other. iOS pauses it for calls, which the [Renderer] tells Clementine.
@MainActor
final class AVPlayback: Playback {
    weak var listener: PlaybackListener?

    /// Holds KVO, notification, and timer tokens behind an NSLock so `deinit` (which is
    /// nonisolated on a @MainActor class) can always tear them down if `stop()` wasn't called.
    private final class CleanupBag: @unchecked Sendable {
        private let lock = NSLock()
        private var kvo: NSKeyValueObservation?
        private var routeObserver: NSObjectProtocol?
        private var timer: Timer?

        func attach(kvo: NSKeyValueObservation, routeObserver: NSObjectProtocol, timer: Timer) {
            lock.lock()
            let oldKVO = self.kvo
            let oldRoute = self.routeObserver
            let oldTimer = self.timer
            self.kvo = kvo
            self.routeObserver = routeObserver
            self.timer = timer
            lock.unlock()
            oldKVO?.invalidate()
            if let oldRoute { NotificationCenter.default.removeObserver(oldRoute) }
            oldTimer?.invalidate()
        }

        func clear() {
            lock.lock()
            let kvo = self.kvo
            let routeObserver = self.routeObserver
            let timer = self.timer
            self.kvo = nil
            self.routeObserver = nil
            self.timer = nil
            lock.unlock()
            kvo?.invalidate()
            if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
            timer?.invalidate()
        }

        deinit {
            clear()
        }
    }

    private let onActivateAudio: @MainActor () -> Void
    private let onDeactivateAudio: @MainActor () -> Void

    private var player: AVQueuePlayer?
    private var volume: Float = 1
    /// What's playing, and what's queued to follow it. Kept here rather than read from the
    /// player, which may have moved on by the time it says an item ended.
    private var current: AVPlayerItem?
    private var queued: AVPlayerItem?
    /// Monotonic counter so async `AVPlayerItem.seek` completions ignore superseded seeks or clears.
    private var seekGeneration: UInt64 = 0
    private let cleanup = CleanupBag()
    /// Per item: its status, and the notifications of its end.
    private var itemObservations: [ObjectIdentifier: [Any]] = [:]
    /// Per item: the bytes it has fetched that are already counted in [Traffic].
    private var counted: [ObjectIdentifier: Int] = [:]

    init(
        onActivateAudio: @escaping @MainActor () -> Void = {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try? session.setActive(true)
        },
        onDeactivateAudio: @escaping @MainActor () -> Void = {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    ) {
        self.onActivateAudio = onActivateAudio
        self.onDeactivateAudio = onDeactivateAudio
    }

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
        onActivateAudio()
        let player = makePlayer()
        clear()
        let item = makeItem(source)
        current = item
        player.insert(item, after: nil)
        if startMs > 0 {
            let generation = seekGeneration
            item.seek(
                to: CMTime(value: startMs, timescale: 1000),
                toleranceBefore: .zero, toleranceAfter: .zero
            ) { @Sendable [weak self, weak item] _ in
                // Notify only once AVPlayerItem finishes seeking so Desktop gets the post-seek
                // timestamp rather than the pre-seek position.
                Task { @MainActor in
                    guard let self, let item, item === self.current, self.seekGeneration == generation else { return }
                    self.listener?.playbackSeeked()
                }
            }
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
        onActivateAudio()
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seek(toMs positionMs: Int64) {
        guard let item = current else { return }
        seekGeneration &+= 1
        let generation = seekGeneration
        item.seek(
            to: CMTime(value: positionMs, timescale: 1000),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { @Sendable [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, item === self.current, self.seekGeneration == generation else { return }
                self.listener?.playbackSeeked()
            }
        }
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        player?.volume = volume
    }

    func stop() {
        guard let player else { return }
        player.pause()
        clear()
        cleanup.clear()
        self.player = nil
        onDeactivateAudio()
        listener?.playbackStateChanged()
    }

    // MARK: Player

    private func makePlayer() -> AVQueuePlayer {
        if let player {
            return player
        }
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        let playerObservation = player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.listener?.playbackStateChanged() }
        }
        let routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            // Pause when headphones or Bluetooth disconnect instead of playing out of the speaker.
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
        self.player = player
        // Twice a second, as the connection sheet reads it.
        let trafficTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countTraffic() }
        }
        cleanup.attach(kvo: playerObservation, routeObserver: routeObserver, timer: trafficTimer)
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
        seekGeneration &+= 1
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
        // Capture item weakly and check object identity (===) so late callbacks can't collide with
        // reused ObjectIdentifiers after an item is forgotten.
        itemObservations[id] = [
            item.observe(\.status) { @Sendable [weak self, weak item] observed, _ in
                let failure = observed.status == .failed ? AVPlayback.describe(observed.error) : nil
                Task { @MainActor in
                    guard let self, let item, item === self.current || item === self.queued else { return }
                    self.listener?.playbackStateChanged()
                    if let failure {
                        self.failed(item, message: failure.message, transient: failure.transient)
                    }
                }
            },
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak item] _ in
                MainActor.assumeIsolated {
                    guard let item else { return }
                    self?.ended(item)
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak item] notification in
                // Stopping partway through is the network's doing: worth loading again.
                let message = AVPlayback.describe(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error).message
                MainActor.assumeIsolated {
                    guard let item else { return }
                    self?.failed(item, message: message, transient: true)
                }
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

    /// [item] played to its end: the queued item follows, if there's one.
    private func ended(_ item: AVPlayerItem) {
        guard let ended = current, ended === item else { return }
        seekGeneration &+= 1
        forget(ended)
        current = queued
        queued = nil
        if current != nil {
            listener?.playbackAdvanced()
        } else {
            listener?.playbackEnded()
        }
    }

    private func failed(_ item: AVPlayerItem, message: String, transient: Bool) {
        // Only the item playing matters: a queued one is loaded again if Clementine sends it.
        guard let current, current === item else { return }
        listener?.playbackFailed(message, transient: transient)
    }

    /// What went wrong, and whether it's the network's doing, worth trying again.
    private nonisolated static func describe(_ error: Error?) -> (message: String, transient: Bool) {
        guard let error = error as NSError? else { return ("Playback failed", false) }
        return (error.localizedDescription, isTransientNetwork(error))
    }

    private nonisolated static func isTransientNetwork(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain, [
            NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
        ].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, [
            Int(ECONNRESET), Int(ETIMEDOUT), Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH), Int(EPIPE),
        ].contains(error.code) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            // AVFoundation often wraps the real NSURL/POSIX network drop inside NSUnderlyingErrorKey.
            return isTransientNetwork(underlying)
        }
        return false
    }
}
