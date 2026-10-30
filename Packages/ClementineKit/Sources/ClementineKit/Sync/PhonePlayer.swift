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

    /// [song], downloaded to this phone, to play with what's kept; its file is its key.
    public init(_ song: DownloadedSong) {
        itemKey = song.file.absoluteString
        title = song.title
        artist = song.artist
        album = song.album
        length = ""
        file = song.file
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
    /// Whether the songs after this one play in random order.
    public private(set) var isShuffled = false
    /// Nothing (.off), all the songs (.playlist) or the one playing (.track).
    public private(set) var repeatMode = RepeatMode.off
    /// The cover in the song's file, once read, if it has one.
    public private(set) var artwork: Data?
    @ObservationIgnored public var onUpdate: (() -> Void)?

    @ObservationIgnored private var player: AVQueuePlayer?
    /// The songs in the order they play.
    @ObservationIgnored private var songs: [KeptSong] = []
    /// Each item's place in [songs].
    @ObservationIgnored private var places: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The songs as they were chosen, for the order to go back to when shuffling stops.
    @ObservationIgnored private var chosen: [KeptSong] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// The song [artwork] is, or is being read, for.
    @ObservationIgnored private var artworkFor: String?

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
        chosen = songs
        isShuffled = shuffled
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

    /// Plays the songs after this one at random, or, shuffled, in the order they were chosen.
    public func toggleShuffle() {
        guard let current = player?.currentItem, let place = places[ObjectIdentifier(current)] else { return }
        isShuffled.toggle()
        let upcoming = Self.upcoming(Array(songs[(place + 1)...]), chosen: chosen, shuffled: isShuffled)
        songs = Array(songs[...place]) + upcoming
        queue(after: current, at: place)
        update()
    }

    /// Moves to the next repeat mode: off, then all the songs, then the one playing.
    public func cycleRepeat() -> RepeatMode {
        repeatMode = switch repeatMode {
        case .off: .playlist
        case .playlist: .track
        default: .off
        }
        onUpdate?()
        return repeatMode
    }

    /// The songs still to play, [remaining], in random order, or in the order they were
    /// [chosen].
    nonisolated static func upcoming(_ remaining: [KeptSong], chosen: [KeptSong], shuffled: Bool) -> [KeptSong] {
        if shuffled {
            return remaining.shuffled()
        }
        let keys = Set(remaining.map(\.itemKey))
        return chosen.filter { keys.contains($0.itemKey) }
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

    /// Queues the songs after [place] behind [current], which plays on.
    private func queue(after current: AVPlayerItem, at place: Int) {
        guard let player else { return }
        for item in player.items() where item !== current {
            player.remove(item)
        }
        places = [ObjectIdentifier(current): place]
        var last = current
        for index in (place + 1)..<songs.count {
            let item = AVPlayerItem(url: songs[index].file)
            places[ObjectIdentifier(item)] = index
            player.insert(item, after: last)
            last = item
        }
    }

    /// A song ended: repeats it, or all the songs after the last, as [repeatMode] says.
    private func ended(_ item: AVPlayerItem) {
        guard let place = places[ObjectIdentifier(item)] else { return }
        switch repeatMode {
        case .track:
            start(at: place)
        case .playlist where place == songs.count - 1:
            start(at: 0)
        default:
            break
        }
    }

    private func makePlayer() -> AVQueuePlayer {
        let player = AVQueuePlayer()
        self.player = player
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { self?.ended(item) }
        }
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
        readArtwork()
        onUpdate?()
    }

    /// Reads the cover in the playing song's file, when the song changes.
    private func readArtwork() {
        guard song?.itemKey != artworkFor else { return }
        artworkFor = song?.itemKey
        artwork = nil
        guard let key = artworkFor, let file = song?.file else { return }
        Task {
            let data = await Self.artwork(in: file)
            guard artworkFor == key, let data else { return }
            artwork = data
            onUpdate?()
        }
    }

    nonisolated private static func artwork(in file: URL) async -> Data? {
        guard let metadata = try? await AVURLAsset(url: file).load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue) {
                return data
            }
        }
        return nil
    }

    /// The song playing, or paused, as the app's player shows a song, with its cover.
    public var playingSong: Song? {
        guard let song else { return nil }
        var metadata = SongMetadata()
        metadata.title = song.title
        metadata.artist = song.artist
        metadata.album = song.album
        metadata.filename = song.file.path
        metadata.isLocal = true
        if let duration {
            metadata.length = Int32(duration.rounded())
        }
        metadata.prettyLength = song.length
        if let artwork {
            metadata.art = artwork
        }
        return Song(metadata)
    }

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        #endif
    }
}
