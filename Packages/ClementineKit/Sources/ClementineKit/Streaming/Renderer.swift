import Foundation
import Observation

/// One track as Clementine sends it to a renderer: where to fetch it, and how to seek in it.
public typealias RenderItem = Pb_Remote_RenderItem

/// What a renderer can play, sent when connecting.
public typealias RendererCapabilities = Pb_Remote_RendererCapabilities

/// Something a renderer can play: a URL on Clementine's media server, and its type.
public struct PlaybackSource: Sendable, Equatable {
    public var url: URL
    /// As Clementine gives it, such as "audio/mpeg" or "audio/flac".
    public var mimeType: String

    public init(url: URL, mimeType: String) {
        self.url = url
        self.mimeType = mimeType
    }
}

public enum PlaybackState: Sendable, Equatable {
    case idle, buffering, playing, paused
}

/// Hears what a [Playback] does, on the main actor.
@MainActor
public protocol PlaybackListener: AnyObject {
    /// [Playback.state] changed.
    func playbackStateChanged()
    /// The item playing finished, and the queued one started.
    func playbackAdvanced()
    /// The item playing finished, with nothing queued.
    func playbackEnded()
    /// The item playing failed; [transient] for a network problem worth reloading, rather than an
    /// item that can't be played.
    func playbackFailed(_ message: String, transient: Bool)
}

/// The audio player a [Renderer] drives: one item playing, and optionally the next one queued to
/// follow it without a gap.
@MainActor
public protocol Playback: AnyObject {
    var listener: PlaybackListener? { get set }
    var state: PlaybackState { get }
    /// Within the URL playing, in milliseconds.
    var positionMs: Int64 { get }
    /// How much of the item has arrived, from 0 to 100.
    var bufferedPercent: Int { get }
    /// Replaces what's playing and queued with [source], from [startMs] within it.
    func load(_ source: PlaybackSource, startMs: Int64, playing: Bool)
    /// Queues [source] to follow what's playing, replacing anything queued; nil clears the queue.
    func queue(_ source: PlaybackSource?)
    func play()
    func pause()
    func seek(toMs positionMs: Int64)
    /// From 0 to 1.
    func setVolume(_ volume: Float)
    func stop()
}

/// This device as Clementine's audio output: plays the items Clementine sends (`RENDER_*`) with a
/// [Playback], and reports back what it's doing, so Clementine, and every remote showing it,
/// follows. Clementine stays in charge: it decides what plays, and when to skip or stop.
///
/// The Android remote's Renderer, for the same protocol.
@MainActor
@Observable
public final class Renderer {
    /// The track playing or loading, as Clementine described it; nil when idle.
    public private(set) var item: RenderItem?
    /// Whether Clementine wants [item] playing, rather than paused.
    public private(set) var isPlaying = false

    /// Where the track is, in milliseconds.
    public var positionMs: Int64 {
        guard let item else { return 0 }
        let position = offsetMs + playback.positionMs
        return item.lengthMs > 0 ? min(position, item.lengthMs) : position
    }

    /// Called whenever the renderer tells Clementine something, for the lock screen.
    @ObservationIgnored public var onUpdate: (@MainActor () -> Void)?

    @ObservationIgnored private let playback: Playback
    @ObservationIgnored private let send: @MainActor (RemoteMessage) -> Void
    @ObservationIgnored private let statusInterval: Duration
    /// Queued to follow [item].
    @ObservationIgnored private var next: RenderItem?
    /// Where the URL playing starts within [item]: an item seeked by loading a new URL
    /// ([SeekMethod.newURL]) starts where the seek went.
    @ObservationIgnored private var offsetMs: Int64 = 0
    @ObservationIgnored private var reported: Pb_Remote_RendererState?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    /// Plays with [playback], and sends Clementine messages with [send]. While playing, it
    /// reports the position every [statusInterval], as Clementine expects.
    public init(playback: Playback, statusInterval: Duration = .seconds(1), send: @escaping @MainActor (RemoteMessage) -> Void) {
        self.playback = playback
        self.statusInterval = statusInterval
        self.send = send
        playback.listener = self
    }

    /// Handles a message from Clementine; returns whether it was one for the renderer.
    @discardableResult
    public func handle(_ message: RemoteMessage) -> Bool {
        switch message.type {
        case .renderLoad:
            let load = message.requestRenderLoad
            isPlaying = load.startState == .playing
            start(load.item, at: load.startMs)
        case .renderPreload:
            next = message.requestRenderPreload.item
            if item != nil {
                playback.queue(next.flatMap(Self.source))
            }
        case .renderPlay:
            guard item != nil else { return true }
            isPlaying = true
            playback.play()
        case .renderPause:
            guard item != nil else { return true }
            isPlaying = false
            playback.pause()
        case .renderStop:
            clear()
            playback.stop()
            playbackStateChanged()
        case .renderSeek:
            let seek = message.requestRenderSeek
            self.seek(item: seek.itemID, to: seek.positionMs, url: seek.url)
        case .renderSetVolume:
            playback.setVolume(Float(max(0, min(100, message.requestRenderVolume.volume))) / 100)
        default:
            return false
        }
        return true
    }

    /// Stops playing, when the connection to Clementine has gone: Clementine plays elsewhere then.
    public func reset() {
        let wasActive = item != nil
        clear()
        statusTask?.cancel()
        statusTask = nil
        reported = nil
        playback.stop()
        if wasActive {
            onUpdate?()
        }
    }

    private func clear() {
        item = nil
        next = nil
        offsetMs = 0
        isPlaying = false
    }

    /// Plays [item] from [startMs], replacing what's playing and queued.
    private func start(_ item: RenderItem, at startMs: Int64) {
        self.item = item
        next = nil
        reported = nil
        guard let source = Self.source(item) else {
            playbackFailed("Not a URL: \(item.url)", transient: false)
            return
        }
        switch item.seekMethod {
        case .newURL:
            // The URL already starts there.
            offsetMs = startMs
            playback.load(source, startMs: 0, playing: isPlaying)
        case .byteRange:
            offsetMs = 0
            playback.load(source, startMs: startMs, playing: isPlaying)
        default:
            // Live, such as radio: it plays from wherever it is now.
            offsetMs = 0
            playback.load(source, startMs: 0, playing: isPlaying)
        }
        playbackStateChanged()
    }

    private func seek(item itemID: Int32, to positionMs: Int64, url: String) {
        // A seek meant for an item that has since changed.
        guard let item, item.itemID == itemID else { return }
        if !url.isEmpty, let target = URL(string: url) {
            offsetMs = positionMs
            playback.load(PlaybackSource(url: target, mimeType: item.mimeType), startMs: 0, playing: isPlaying)
            playback.queue(next.flatMap(Self.source))
        } else if item.seekMethod == .byteRange {
            offsetMs = 0
            playback.seek(toMs: positionMs)
        } else {
            return
        }
        sendStatus()
    }

    private static func source(_ item: RenderItem) -> PlaybackSource? {
        URL(string: item.url).map { PlaybackSource(url: $0, mimeType: item.mimeType) }
    }

    private var state: Pb_Remote_RendererState {
        guard item != nil else { return .idle }
        switch playback.state {
        case .idle: return .loading
        case .buffering: return isPlaying ? .buffering : .paused
        case .playing: return .playing
        // Includes playback paused by iOS, such as for a call, which Clementine then shows.
        case .paused: return .paused
        }
    }

    private func sendStatus() {
        let state = state
        reported = state
        send(RemoteMessage(.rendererStatus) {
            $0.rendererStatus.itemID = item?.itemID ?? 0
            $0.rendererStatus.state = state
            $0.rendererStatus.positionMs = positionMs
            $0.rendererStatus.bufferedPercent = item == nil ? 0 : Int32(playback.bufferedPercent)
        })
        onUpdate?()
    }

    private func sendTrackEnded(_ itemID: Int32) {
        send(RemoteMessage(.rendererTrackEnded) { $0.rendererTrackEnded.itemID = itemID })
    }

    /// Reports the position while playing, and stops when not.
    private func updateStatusTask(for state: Pb_Remote_RendererState) {
        let moving = state == .playing || state == .buffering
        guard moving else {
            statusTask?.cancel()
            statusTask = nil
            return
        }
        guard statusTask == nil else { return }
        statusTask = Task { [weak self, statusInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: statusInterval)
                guard !Task.isCancelled, let self else { return }
                self.sendStatus()
            }
        }
    }
}

extension Renderer: PlaybackListener {
    public func playbackStateChanged() {
        let state = state
        updateStatusTask(for: state)
        if state != reported {
            sendStatus()
        }
    }

    public func playbackAdvanced() {
        guard let ended = item else { return }
        item = next
        next = nil
        offsetMs = 0
        // Clementine hears of the switch first, so the status that follows is about the item it
        // now considers current.
        sendTrackEnded(ended.itemID)
        reported = nil
        playbackStateChanged()
    }

    public func playbackEnded() {
        guard let ended = item else { return }
        clear()
        sendTrackEnded(ended.itemID)
        playbackStateChanged()
    }

    public func playbackFailed(_ message: String, transient: Bool) {
        guard let item else { return }
        send(RemoteMessage(.rendererError) {
            $0.rendererError.itemID = item.itemID
            $0.rendererError.message = message
            $0.rendererError.scope = transient ? .transient : .item
        })
    }
}

extension Renderer {
    /// What the phone can play, to send when connecting: an [id] Clementine recognises it by, the
    /// [name] it shows, and the types AVFoundation plays (not Ogg, which Clementine converts).
    public static func capabilities(id: String, name: String) -> RendererCapabilities {
        var capabilities = RendererCapabilities()
        capabilities.rendererID = id
        capabilities.displayName = name
        capabilities.formats = formats.map { type in
            var format = Pb_Remote_AudioFormat()
            format.mimeType = type
            return format
        }
        // AVQueuePlayer starts a queued item without a gap, and seeks with Range requests.
        capabilities.features = [.gapless, .httpRange]
        return capabilities
    }

    /// The types AVFoundation plays, as Clementine names them.
    public static let formats = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/wav", "audio/aiff"]
}
