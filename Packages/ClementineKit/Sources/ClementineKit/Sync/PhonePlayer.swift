import AVFoundation
import Foundation
import Observation

/// A song kept on this phone, to show and play.
public struct KeptSong: Sendable, Hashable, Identifiable {
    public var itemKey: String
    public var title: String
    public var artist: String
    public var album: String
    /// As Clementine writes it, such as "5:36"; empty if it didn't say.
    public var length: String
    public var file: URL

    public var id: String { itemKey }

    /// [item], in [folder], as its tags have it; a song without a title is named after its file.
    public init(_ item: SyncedItem, in folder: URL) {
        let song = (try? SongMetadata(serializedBytes: item.metadata)) ?? SongMetadata()
        let file = folder.appending(path: item.path)
        itemKey = item.itemKey
        title = song.title.isEmpty ? file.deletingPathExtension().lastPathComponent : song.title
        artist = song.artist.isEmpty ? song.albumartist : song.artist
        album = song.album
        length = song.prettyLength
        self.file = file
    }
}

/// Plays songs kept on this phone, without Clementine, and says which is playing. It plays as
/// music: in the background, and on AirPlay or Bluetooth like any other. [onUpdate] hears each
/// change, for the lock screen.
@MainActor
@Observable
public final class PhonePlayer {
    /// The song playing on this phone, or paused there; nil when nothing is.
    public private(set) var song: KeptSong?
    public private(set) var isPlaying = false
    @ObservationIgnored public var onUpdate: (() -> Void)?

    @ObservationIgnored private var player: AVQueuePlayer?
    /// The songs in the order they play.
    @ObservationIgnored private var songs: [KeptSong] = []
    /// Each item's place in [songs].
    @ObservationIgnored private var places: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    public init() {}

    /// The item key of the song playing, or paused.
    public var playing: String? { song?.itemKey }

    /// Where the song is, in seconds.
    public var position: Double {
        guard let time = player?.currentItem?.currentTime(), time.isNumeric else { return 0 }
        return time.seconds
    }

    /// The song's length in seconds, once it's known.
    public var duration: Double? {
        guard let time = player?.currentItem?.duration, time.isNumeric, time.seconds > 0 else { return nil }
        return time.seconds
    }

    /// The order [songs] play in from the one at [start]: from it in order, or every one at
    /// random.
    nonisolated static func order(_ songs: [KeptSong], from start: Int, shuffled: Bool) -> [KeptSong] {
        guard !songs.isEmpty else { return [] }
        if shuffled {
            return songs.shuffled()
        }
        return Array(songs[min(max(start, 0), songs.count - 1)...])
    }

    /// Plays [songs] from the one at [index], or all of them at random.
    public func play(_ songs: [KeptSong], from index: Int, shuffled: Bool = false) {
        self.songs = Self.order(songs, from: index, shuffled: shuffled)
        guard !self.songs.isEmpty else { return }
        start(at: 0)
    }

    public func play() {
        guard song != nil else { return }
        activateSession()
        player?.play()
    }

    public func pause() {
        player?.pause()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func next() {
        player?.advanceToNextItem()
    }

    /// Back to the start of the song, or, near its start, the song before.
    public func previous() {
        guard let current = player?.currentItem, let place = places[ObjectIdentifier(current)] else { return }
        if position > 3 || place == 0 {
            seek(to: 0)
        } else {
            start(at: place - 1)
        }
    }

    public func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        onUpdate?()
    }

    /// Stops, and forgets the songs.
    public func stop() {
        player?.pause()
        player?.removeAllItems()
        songs = []
        places = [:]
        update()
    }

    private func start(at place: Int) {
        activateSession()
        let player = player ?? makePlayer()
        player.removeAllItems()
        places = [:]
        for index in place..<songs.count {
            let item = AVPlayerItem(url: songs[index].file)
            places[ObjectIdentifier(item)] = index
            player.insert(item, after: nil)
        }
        player.play()
        update()
    }

    private func makePlayer() -> AVQueuePlayer {
        let player = AVQueuePlayer()
        self.player = player
        // KVO can call back on any thread: the handlers hop to the main actor.
        observations = [
            player.observe(\.currentItem) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.update() }
            },
            player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.update() }
            },
        ]
        return player
    }

    private func update() {
        let place = player?.currentItem.flatMap { places[ObjectIdentifier($0)] }
        song = place.map { songs[$0] }
        isPlaying = song != nil && player?.timeControlStatus != .paused
        onUpdate?()
    }

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        #endif
    }
}
