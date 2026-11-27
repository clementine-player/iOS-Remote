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
    /// The cover Clementine sent with the song, if it did. Otherwise the cover is the one in
    /// [file], if it has one.
    public var artFile: URL?

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
        artFile = item.artKey.flatMap(SyncFiles.artPath(key:)).map { folder.appending(path: $0) }
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
    /// The song's cover, once read, if it has one.
    public private(set) var artwork: Data?
    @ObservationIgnored public var onUpdate: (() -> Void)?
    /// Optional coordinator invoked instead of activating AVAudioSession directly, so the app can
    /// stop conflicting playback modes cleanly.
    @ObservationIgnored public var onActivateAudio: (@MainActor () -> Void)?

    // Pairs each AVPlayerItem with its queue index and per-item KVO tokens, retaining the item
    // so its ObjectIdentifier cannot be reused while tracked; callbacks match items with ===.
    private final class QueuedItem {
        let item: AVPlayerItem
        var index: Int
        var statusObserver: NSKeyValueObservation?
        var durationObserver: NSKeyValueObservation?

        init(item: AVPlayerItem, index: Int) {
            self.item = item
            self.index = index
        }

        deinit {
            statusObserver?.invalidate()
            durationObserver?.invalidate()
        }
    }

    // PhonePlayer is @MainActor, so its deinit can run off the main actor; NSLock lets
    // ObserverBag invalidate KVO and NotificationCenter observers safely from deinit.
    private final class ObserverBag: @unchecked Sendable {
        private let lock = NSLock()
        private var kvos: [NSKeyValueObservation] = []
        private var notifications: [NSObjectProtocol] = []

        func set(kvos: [NSKeyValueObservation], notifications: [NSObjectProtocol]) {
            lock.lock()
            let oldKVOs = self.kvos
            let oldNotifications = self.notifications
            self.kvos = kvos
            self.notifications = notifications
            lock.unlock()
            for kvo in oldKVOs { kvo.invalidate() }
            for token in oldNotifications { NotificationCenter.default.removeObserver(token) }
        }

        deinit {
            lock.lock()
            let kvos = self.kvos
            let notifications = self.notifications
            self.kvos = []
            self.notifications = []
            lock.unlock()
            for kvo in kvos { kvo.invalidate() }
            for token in notifications { NotificationCenter.default.removeObserver(token) }
        }
    }

    // Keep only 2 upcoming AVPlayerItems queued instead of allocating items for an entire library.
    private static let lookaheadCount = 2

    @ObservationIgnored private var player: AVQueuePlayer?
    /// The songs in the order they play.
    @ObservationIgnored private var songs: [KeptSong] = []
    /// Items currently held in [player] (current + windowed lookahead), preserving each item's
    /// KVO observers and exact index in [songs] without `ObjectIdentifier` reuse hazards.
    @ObservationIgnored private var queuedItems: [QueuedItem] = []
    /// Target position in seconds of an in-flight seek so `position` doesn't flash the pre-seek time.
    @ObservationIgnored private var pendingSeek: Double?
    // Discards stale seek completions after a newer seek, track change, or stop().
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var observedItemID: ObjectIdentifier?
    /// The songs as they were chosen, for the order to go back to when shuffling stops.
    @ObservationIgnored private var chosen: [KeptSong] = []
    @ObservationIgnored private let observerBag = ObserverBag()
    /// The song [artwork] is, or is being read, for.
    @ObservationIgnored private var artworkFor: String?

    public init() {}

    /// The item key of the song playing, or paused.
    public var playing: String? { song?.itemKey }

    /// Where the song is, in seconds.
    public var position: Double {
        if let pendingSeek { return pendingSeek }
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
        if let onActivateAudio {
            onActivateAudio()
        } else {
            activateSession()
        }
        player?.play()
    }

    public func pause() {
        player?.pause()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func next() {
        guard let place = currentPlace else { return }
        if place + 1 < songs.count {
            player?.advanceToNextItem()
        } else if repeatMode == .playlist {
            start(at: 0)
        } else {
            player?.advanceToNextItem()
        }
    }

    /// Back to the start of the song, or, near its start, the song before.
    public func previous() {
        guard let place = currentPlace else { return }
        if position > 3 || place == 0 {
            seek(to: 0)
        } else {
            start(at: place - 1)
        }
    }

    public func seek(to seconds: Double) {
        seekGeneration &+= 1
        let generation = seekGeneration
        pendingSeek = seconds
        onUpdate?()
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 1000),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.pendingSeek = nil
                self.onUpdate?()
            }
        }
    }

    /// Plays the songs after this one at random, or, shuffled, in the order they were chosen.
    public func toggleShuffle() {
        guard let current = player?.currentItem, let place = place(for: current) else { return }
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
        // Hold at end (.none) during .track repeat so AVQueuePlayer doesn't briefly start
        // the next queued item before didPlayToEndTimeNotification seeks back to zero.
        player?.actionAtItemEnd = repeatMode == .track ? .none : .advance
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
        seekGeneration &+= 1
        pendingSeek = nil
        observedItemID = nil
        player?.pause()
        player?.removeAllItems()
        songs = []
        queuedItems = []
        artworkFor = nil
        artwork = nil
        update()
    }

    private var currentPlace: Int? {
        player?.currentItem.flatMap { place(for: $0) }
    }

    private func place(for item: AVPlayerItem) -> Int? {
        queuedItems.first(where: { $0.item === item })?.index
    }

    private func makeQueuedItem(at index: Int) -> QueuedItem {
        let avItem = AVPlayerItem(url: songs[index].file)
        let queued = QueuedItem(item: avItem, index: index)
        // Skip broken local files instead of stalling, and refresh NowPlaying once AVPlayerItem
        // resolves duration asynchronously so lock-screen scrubbing becomes available.
        queued.statusObserver = avItem.observe(\.status) { @Sendable [weak self, weak avItem] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self, weak avItem] in
                guard let self, let avItem, avItem === self.player?.currentItem else { return }
                self.next()
            }
        }
        queued.durationObserver = avItem.observe(\.duration) { @Sendable [weak self, weak avItem] _, _ in
            Task { @MainActor [weak self, weak avItem] in
                guard let self, let avItem, avItem === self.player?.currentItem else { return }
                self.onUpdate?()
            }
        }
        return queued
    }

    private func start(at place: Int) {
        guard !songs.isEmpty, (0..<songs.count).contains(place) else { return }
        seekGeneration &+= 1
        pendingSeek = nil
        observedItemID = nil
        if let onActivateAudio {
            onActivateAudio()
        } else {
            activateSession()
        }
        let player = player ?? makePlayer()
        player.actionAtItemEnd = repeatMode == .track ? .none : .advance
        player.removeAllItems()
        queuedItems = []
        let end = min(songs.count, place + 1 + Self.lookaheadCount)
        for index in place..<end {
            let queued = makeQueuedItem(at: index)
            queuedItems.append(queued)
            player.insert(queued.item, after: nil)
        }
        player.play()
        update()
    }

    /// Queues the windowed songs after [place] behind [current], which plays on.
    private func queue(after current: AVPlayerItem, at place: Int) {
        guard let player else { return }
        for item in player.items() where item !== current {
            player.remove(item)
        }
        queuedItems.removeAll { $0.item !== current }
        if let currentEntry = queuedItems.first(where: { $0.item === current }) {
            currentEntry.index = place
        }
        fillWindow(after: place)
    }

    private func fillWindow(after currentPlace: Int) {
        guard let player else { return }
        // Prune items already advanced past or removed by AVQueuePlayer before topping up lookahead.
        let liveItems = Set(player.items().map(ObjectIdentifier.init))
        queuedItems.removeAll { !liveItems.contains(ObjectIdentifier($0.item)) }

        let targetEnd = min(songs.count, currentPlace + 1 + Self.lookaheadCount)
        let nextStart = (queuedItems.map(\.index).max() ?? currentPlace) + 1
        guard nextStart < targetEnd else { return }
        for index in nextStart..<targetEnd {
            let queued = makeQueuedItem(at: index)
            queuedItems.append(queued)
            player.insert(queued.item, after: nil)
        }
    }

    /// A song ended: repeats it, or all the songs after the last, as [repeatMode] says.
    private func ended(_ item: AVPlayerItem) {
        guard let place = place(for: item) else { return }
        switch repeatMode {
        case .track:
            item.seek(to: .zero) { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.player?.play()
                    self?.update()
                }
            }
        case .playlist where place == songs.count - 1:
            start(at: 0)
        default:
            break
        }
    }

    private func makePlayer() -> AVQueuePlayer {
        let player = AVQueuePlayer()
        player.actionAtItemEnd = repeatMode == .track ? .none : .advance
        self.player = player

        var notifications: [NSObjectProtocol] = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let item = notification.object as? AVPlayerItem else { return }
                MainActor.assumeIsolated { self?.ended(item) }
            }
        ]
        #if os(iOS)
        notifications.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
            ) { [weak self] notification in
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                MainActor.assumeIsolated {
                    guard let self, let rawType,
                          let type = AVAudioSession.InterruptionType(rawValue: rawType)
                    else { return }
                    switch type {
                    case .began:
                        self.update()
                    case .ended:
                        if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume),
                           self.song != nil {
                            self.play()
                        } else {
                            self.update()
                        }
                    @unknown default:
                        break
                    }
                }
            }
        )
        #endif

        // KVO can call back on any thread: the handlers hop to the main actor.
        let kvos = [
            player.observe(\.currentItem) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.update() }
            },
            player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.update() }
            },
        ]
        observerBag.set(kvos: kvos, notifications: notifications)
        return player
    }

    private func update() {
        let currentItemID = player?.currentItem.map(ObjectIdentifier.init)
        if currentItemID != observedItemID {
            observedItemID = currentItemID
            seekGeneration &+= 1
            pendingSeek = nil
        }
        let place = currentPlace
        if let place {
            fillWindow(after: place)
        }
        song = place.map { songs[$0] }
        isPlaying = song != nil && player?.timeControlStatus != .paused
        readArtwork()
        onUpdate?()
    }

    /// Reads the playing song's cover, when the song changes: the one Clementine sent, or else the
    /// one in its file.
    private func readArtwork() {
        guard song?.itemKey != artworkFor else { return }
        artworkFor = song?.itemKey
        artwork = nil
        guard let key = artworkFor, let file = song?.file else { return }
        let artFile = song?.artFile
        Task {
            let data = await Self.artwork(artFile, orIn: file)
            guard artworkFor == key, let data else { return }
            artwork = data
            onUpdate?()
        }
    }

    nonisolated private static func artwork(_ artFile: URL?, orIn file: URL) async -> Data? {
        if let artFile, let data = try? Data(contentsOf: artFile), !data.isEmpty {
            return data
        }
        return await artwork(in: file)
    }

    nonisolated static func artwork(in file: URL) async -> Data? {
        if let metadata = try? await AVURLAsset(url: file).load(.commonMetadata) {
            for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
                if let data = try? await item.load(.dataValue), !data.isEmpty {
                    return data
                }
            }
        }
        return flacPicture(in: file)
    }

    /// Reads an embedded `METADATA_BLOCK_PICTURE` block (type 6) from a FLAC file header without
    /// loading the full audio stream into memory. Prefers Front Cover (type 3).
    nonisolated static func flacPicture(in file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var fallback: Data?
        while let header = try? handle.read(upToCount: 4), header.count == 4 {
            let isLast = (header[0] & 0x80) != 0
            let blockType = header[0] & 0x7F
            let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            guard length >= 0 else { break }

            // Cap picture block reads at 32 MiB to reject corrupt/oversized metadata headers.
            if blockType == 6, length <= 32 * 1024 * 1024 {
                guard let block = try? handle.read(upToCount: length), block.count == length else { break }
                if let parsed = parseFLACPictureBlock(block) {
                    if parsed.pictureType == 3 {
                        return parsed.data
                    }
                    if fallback == nil {
                        fallback = parsed.data
                    }
                }
            } else {
                guard let offset = try? handle.offset() else { break }
                try? handle.seek(toOffset: offset + UInt64(length))
            }
            if isLast { break }
        }
        return fallback
    }

    nonisolated private static func parseFLACPictureBlock(_ block: Data) -> (pictureType: UInt32, data: Data)? {
        func readUInt32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= block.count else { return nil }
            let base = block.startIndex + offset
            return (UInt32(block[base]) << 24)
                | (UInt32(block[base + 1]) << 16)
                | (UInt32(block[base + 2]) << 8)
                | UInt32(block[base + 3])
        }

        var cursor = 0
        guard let pictureType = readUInt32(at: cursor) else { return nil }
        cursor += 4
        guard let mimeLen = readUInt32(at: cursor), mimeLen <= block.count - (cursor + 4) else { return nil }
        cursor += 4
        let mimeStart = block.startIndex + cursor
        let mime = String(data: block[mimeStart..<(mimeStart + Int(mimeLen))], encoding: .utf8)
        cursor += Int(mimeLen)
        // Per the FLAC spec, MIME "-->" indicates an external URI rather than embedded image bytes.
        guard mime != "-->" else { return nil }

        guard let descLen = readUInt32(at: cursor), descLen <= block.count - (cursor + 4) else { return nil }
        cursor += 4 + Int(descLen)
        // Skip width, height, depth, color count (16 bytes), then data length (4 bytes).
        guard cursor + 16 <= block.count, let dataLen = readUInt32(at: cursor + 16) else { return nil }
        cursor += 20
        guard dataLen > 0, Int(dataLen) <= block.count - cursor else { return nil }
        let dataStart = block.startIndex + cursor
        return (pictureType, Data(block[dataStart..<(dataStart + Int(dataLen))]))
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
