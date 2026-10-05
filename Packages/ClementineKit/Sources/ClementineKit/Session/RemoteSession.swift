import Foundation
import Observation

/// Clementine as the app knows it: the connection, what's playing, and the playlists. Screens
/// read it and call its commands; Clementine's answers update it.
@MainActor
@Observable
public final class RemoteSession {

    public enum Status: Sendable, Equatable {
        case disconnected
        /// Connecting, before Clementine has said anything.
        case connecting
        /// Connected, and Clementine is sending what it's doing.
        case downloadingData
        case connected
        /// The connection dropped; trying to restore it.
        case reconnecting
        /// Disconnected while the app is in the background, to reconnect on return.
        case suspended

        /// Showing Clementine: the tabs rather than the connect screen.
        public var isActive: Bool {
            self == .connected || self == .reconnecting || self == .suspended
        }

        /// Busy connecting from the connect screen.
        public var isConnecting: Bool {
            self == .connecting || self == .downloadingData
        }
    }

    // MARK: Connection

    public private(set) var status = Status.disconnected
    public private(set) var endpoint: Endpoint?
    /// Clementine's name on the network, or its address.
    public private(set) var hostName = ""
    public private(set) var authCode: Int32 = 0
    /// Why the last connection ended, if it wasn't asked to. Cleared when connecting again.
    public private(set) var closeReason: ClementineConnection.CloseReason?
    public private(set) var clementineVersion = ""
    public private(set) var connectedSince: Date?
    /// What this device offered Clementine when connecting, if it offered to play.
    public private(set) var renderer: RendererCapabilities?

    // MARK: Outputs

    /// Whether this Clementine can play elsewhere than on its own computer (remote streaming).
    public private(set) var canChooseOutput = false
    /// Where Clementine can play: its computer and the renderers connected to it.
    public private(set) var outputs: [Output] = []

    /// Where Clementine plays now.
    public var activeOutput: Output? {
        outputs.first { $0.state == .active }
    }

    /// Whether there's anywhere to play but Clementine's computer.
    public var hasOtherOutputs: Bool {
        canChooseOutput && outputs.count > 1
    }

    /// Whether Clementine plays on this device.
    public var isPlayingHere: Bool {
        guard let renderer, let activeOutput else { return false }
        return activeOutput.id == renderer.rendererID
    }

    // MARK: Internet

    /// Whether this Clementine can be browsed like its Internet sidebar, for its internet services.
    public private(set) var canBrowse = false

    // MARK: Playing

    public private(set) var song: Song?
    public private(set) var playState = PlayState.stopped
    /// In seconds.
    public private(set) var position = 0
    /// From 0 to 100.
    public private(set) var volume = 100
    public private(set) var shuffleMode = ShuffleMode.off
    public private(set) var repeatMode = RepeatMode.off
    /// The current song's lyrics; nil until Clementine sends them.
    public private(set) var lyrics: [Lyrics]?
    public private(set) var isLoved = false

    // MARK: Playlists

    public private(set) var playlists: [Playlist] = []
    public private(set) var activePlaylistID: Int32?
    /// The songs of the playlists downloaded so far, by playlist id.
    public private(set) var playlistSongs: [Int32: [Song]] = [:]
    /// While playlists' songs download: how many of how many have arrived.
    public private(set) var playlistsLoading: (done: Int, total: Int)?

    public var activePlaylist: Playlist? {
        playlists.first { $0.id == activePlaylistID }
    }

    private var connection: ClementineConnection?
    private var sender: AsyncStream<RemoteMessage>.Continuation?
    private var requestedPlaylists: Set<Int32> = []
    private var lyricsRequested = false
    private var refreshPlaylistsWhenReady = false
    private var observers: [UUID: @MainActor (RemoteMessage) -> Void] = [:]

    public init() {}

    // MARK: Connecting

    /// Connects to Clementine at [endpoint], called [name] (its address if nil). With [renderer],
    /// this device offers itself as somewhere Clementine can play.
    public func connect(
        to endpoint: Endpoint, name: String? = nil, authCode: Int32, renderer: RendererCapabilities? = nil
    ) {
        drop()
        reset()
        self.endpoint = endpoint
        hostName = name ?? endpoint.host
        self.authCode = authCode
        self.renderer = renderer
        closeReason = nil
        connectedSince = nil
        status = .connecting
        open(sendPlaylistSongs: true)
    }

    /// Disconnects, and forgets Clementine's state.
    public func disconnect() {
        guard let connection else { return }
        drop()
        Task { await connection.disconnect() }
        reset()
        status = .disconnected
    }

    /// Disconnects quietly for the app's time in the background.
    public func suspend() {
        guard status == .connected || status == .reconnecting, let connection else { return }
        drop()
        Task { await connection.disconnect() }
        status = .suspended
    }

    /// Reconnects after [suspend], then refreshes the playlists.
    public func resume() {
        guard status == .suspended, endpoint != nil else { return }
        status = .reconnecting
        requestedPlaylists = []
        playlistsLoading = nil
        refreshPlaylistsWhenReady = true
        open(sendPlaylistSongs: false)
    }

    /// Sent and received since connecting.
    public func byteCounts() async -> (sent: Int, received: Int) {
        await connection?.byteCounts ?? (sent: 0, received: 0)
    }

    /// Hears every message from Clementine, after the session has applied it. Returns a token for
    /// [removeObserver].
    @discardableResult
    public func addObserver(_ observer: @escaping @MainActor (RemoteMessage) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func open(sendPlaylistSongs: Bool) {
        guard let endpoint else { return }
        let connection = ClementineConnection(endpoint: endpoint, authCode: authCode, renderer: renderer)
        self.connection = connection

        // One queue of commands, so they reach Clementine in order.
        let (commands, sender) = AsyncStream.makeStream(of: RemoteMessage.self)
        self.sender = sender
        Task {
            for await command in commands {
                await connection.send(command)
            }
        }
        Task { [weak self] in
            for await event in connection.events {
                self?.handle(event, from: connection)
            }
        }
        Task { await connection.start(sendPlaylistSongs: sendPlaylistSongs) }
    }

    /// Stops listening to the connection.
    private func drop() {
        sender?.finish()
        sender = nil
        connection = nil
    }

    private func reset() {
        clementineVersion = ""
        song = nil
        playState = .stopped
        position = 0
        volume = 100
        shuffleMode = .off
        repeatMode = .off
        lyrics = nil
        lyricsRequested = false
        isLoved = false
        playlists = []
        activePlaylistID = nil
        playlistSongs = [:]
        playlistsLoading = nil
        requestedPlaylists = []
        refreshPlaylistsWhenReady = false
        canChooseOutput = false
        outputs = []
        canBrowse = false
    }

    private func handle(_ event: ClementineConnection.Event, from source: ClementineConnection) {
        guard source === connection else { return }
        switch event {
        case .connected:
            break
        case .message(let message):
            apply(message)
            for observer in observers.values {
                observer(message)
            }
        case .reconnecting:
            if status == .connected {
                status = .reconnecting
            }
        case .reconnected:
            break
        case .closed(let reason):
            drop()
            reset()
            status = .disconnected
            closeReason = reason == .requested ? nil : reason
        }
    }

    // MARK: Clementine's messages

    /// Updates the session from a message from Clementine.
    func apply(_ message: RemoteMessage) {
        switch message.type {
        case .info:
            let info = message.responseClementineInfo
            clementineVersion = info.version
            playState = PlayState(info.state)
            if status == .connecting {
                status = .downloadingData
            }
            canChooseOutput = info.features.contains(.rendering)
            canBrowse = info.features.contains(.browse)
            if canChooseOutput {
                send(RemoteMessage(.requestOutputs))
            }
        case .outputs:
            outputs = message.responseOutputs.outputs.map(Output.init)
        case .firstDataSentComplete:
            if connectedSince == nil {
                connectedSince = .now
            }
            status = .connected
            if refreshPlaylistsWhenReady {
                refreshPlaylistsWhenReady = false
                let loaded = Set(playlistSongs.keys)
                playlistSongs = [:]
                request(playlists.map(\.id).filter(loaded.contains))
            }
        case .currentMetainfo:
            let current = message.responseCurrentMetadata
            song = current.hasSongMetadata && current.songMetadata.hasID ? Song(current.songMetadata) : nil
            position = 0
            lyrics = nil
            lyricsRequested = false
            isLoved = false
        case .updateTrackPosition:
            position = Int(message.responseUpdateTrackPosition.position)
        case .setVolume:
            volume = Int(message.requestSetVolume.volume)
        case .play:
            playState = .playing
        case .pause:
            playState = .paused
        case .stop:
            playState = .stopped
        case .engineStateChanged:
            playState = PlayState(message.responseEngineStateChanged.state)
        case .repeat:
            repeatMode = RepeatMode(message.repeat.repeatMode)
        case .shuffle:
            shuffleMode = ShuffleMode(message.shuffle.shuffleMode)
        case .playlists:
            let received = message.responsePlaylists.playlist
            playlists = received.map {
                Playlist(id: $0.id, name: $0.name, itemCount: Int($0.itemCount), isClosed: $0.closed)
            }
            if let active = received.first(where: \.active) {
                activePlaylistID = active.id
            }
            let ids = Set(playlists.map(\.id))
            playlistSongs = playlistSongs.filter { ids.contains($0.key) }
        case .playlistSongs:
            let response = message.responsePlaylistSongs
            let id = response.requestedPlaylist.id
            // Clementine numbers the songs by their place, except a song it can't read (a
            // missing file, say), which comes with no fields set: index 0, the first song's.
            // So each is numbered by its place here, which keeps the queue's rows apart and has
            // a tap on one play that song.
            playlistSongs[id] = response.songs.enumerated().map { place, metadata in
                var song = Song(metadata)
                song.index = Int32(place)
                return song
            }
            if requestedPlaylists.remove(id) != nil, let loading = playlistsLoading {
                playlistsLoading = (min(loading.done + 1, loading.total), loading.total)
            }
            if requestedPlaylists.isEmpty {
                playlistsLoading = nil
            }
        case .activePlaylistChanged:
            activePlaylistID = message.responseActiveChanged.id
        case .lyrics:
            let received = message.responseLyrics.lyrics.map {
                Lyrics(provider: $0.id, title: $0.title, content: $0.content)
            }
            lyrics = (lyrics ?? []) + received
        default:
            break
        }
    }

    // MARK: Commands

    /// Sends [message] to Clementine, after the commands before it.
    public func send(_ message: RemoteMessage) {
        sender?.yield(message)
    }

    public func playPause() { send(RemoteMessage(.playpause)) }
    public func play() { send(RemoteMessage(.play)) }
    public func pause() { send(RemoteMessage(.pause)) }
    public func stop() { send(RemoteMessage(.stop)) }
    public func next() { send(RemoteMessage(.next)) }
    public func previous() { send(RemoteMessage(.previous)) }

    /// Toggles stopping once the current song ends.
    public func stopAfterCurrent() { send(RemoteMessage(.stopAfter)) }

    /// Seeks, showing the new position at once.
    public func seek(to seconds: Int) {
        position = seconds
        send(Messages.trackPosition(seconds))
    }

    /// Moves to the next shuffle mode, and returns it.
    @discardableResult
    public func cycleShuffle() -> ShuffleMode {
        shuffleMode = shuffleMode.next
        send(Messages.shuffle(shuffleMode))
        return shuffleMode
    }

    /// Moves to the next repeat mode, and returns it.
    @discardableResult
    public func cycleRepeat() -> RepeatMode {
        repeatMode = repeatMode.next
        send(Messages.repeat(repeatMode))
        return repeatMode
    }

    /// Rates the current song from 0 to 5 stars, showing it at once.
    public func rate(stars: Int) {
        guard song != nil else { return }
        let rating = Float(max(0, min(5, stars))) / 5
        song?.rating = rating
        send(Messages.rate(rating))
    }

    /// Loves the current song on Last.fm; a song can be loved once.
    public func love() {
        guard song != nil, !isLoved else { return }
        isLoved = true
        send(RemoteMessage(.love))
    }

    /// Bans the current song on Last.fm.
    public func ban() {
        guard song != nil else { return }
        send(RemoteMessage(.ban))
    }

    /// Sets Clementine's volume, from 0 to 100.
    public func setVolume(_ percent: Int) {
        volume = max(0, min(100, percent))
        send(Messages.volume(volume))
    }

    /// Changes Clementine's volume by [delta] percent, and returns the new volume.
    @discardableResult
    public func changeVolume(by delta: Int) -> Int {
        setVolume(volume + delta)
        return volume
    }

    /// Asks Clementine for the current song's lyrics, once.
    public func requestLyrics() {
        guard song != nil, !lyricsRequested else { return }
        lyricsRequested = true
        send(RemoteMessage(.getLyrics))
    }

    // MARK: Playlist commands

    /// Asks Clementine for the songs of the playlists not downloaded yet.
    public func loadPlaylistSongs() {
        guard status == .connected, playlistsLoading == nil else { return }
        request(playlists.map(\.id).filter { playlistSongs[$0] == nil })
    }

    private func request(_ ids: [Int32]) {
        let wanted = ids.filter { !requestedPlaylists.contains($0) }
        guard !wanted.isEmpty else { return }
        requestedPlaylists.formUnion(wanted)
        playlistsLoading = (0, wanted.count)
        for id in wanted {
            send(Messages.requestPlaylistSongs(id))
        }
    }

    /// Plays [song] of playlist [playlistID], which becomes the active playlist.
    public func play(_ song: Song, in playlistID: Int32) {
        send(Messages.changeSong(index: song.index, playlistID: playlistID))
        activePlaylistID = playlistID
    }

    public func remove(_ songs: [Song], from playlistID: Int32) {
        guard !songs.isEmpty else { return }
        send(Messages.removeSongs(songs.map(\.index), playlistID: playlistID))
    }

    /// Removes every song from a playlist.
    public func clear(playlistID: Int32) {
        remove(playlistSongs[playlistID] ?? [], from: playlistID)
        playlistSongs[playlistID] = []
    }

    public func close(playlistID: Int32) {
        send(Messages.closePlaylist(playlistID))
    }

    /// Adds songs, by their URLs, to playlist [playlistID], or the active playlist when nil.
    /// With [playIfStopped], plays the first of them unless something is playing already.
    public func add(urls: [String], to playlistID: Int32? = nil, playIfStopped: Bool = false) {
        guard let playlistID = playlistID ?? activePlaylistID, !urls.isEmpty else { return }
        send(Messages.insertURLs(urls, playlistID: playlistID, playNow: playIfStopped && playState != .playing))
    }

    /// Adds songs, described in full, to playlist [playlistID], or the active playlist when nil.
    /// With [playIfStopped], plays the first of them unless something is playing already.
    public func add(songs: [SongMetadata], to playlistID: Int32? = nil, playIfStopped: Bool = false) {
        guard let playlistID = playlistID ?? activePlaylistID, !songs.isEmpty else { return }
        send(Messages.insertSongs(songs, playlistID: playlistID, playNow: playIfStopped && playState != .playing))
    }

    /// Creates a playlist called [name], and returns it once Clementine has; nil if Clementine
    /// doesn't say it has in [timeout] (Clementine before 1.4 can't create playlists).
    public func createPlaylist(named name: String, timeout: Duration = .seconds(5)) async -> Playlist? {
        let before = Set(playlists.map(\.id))
        send(Messages.createPlaylist(named: name))
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, status.isActive {
            if let created = playlists.first(where: { !before.contains($0.id) }) {
                return created
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    public func search(_ query: String) {
        send(Messages.globalSearch(query))
    }

    // MARK: Output commands

    /// Asks Clementine to play on output [id], showing it as switching until Clementine says.
    public func setOutput(_ id: String) {
        guard let index = outputs.firstIndex(where: { $0.id == id }), outputs[index].state != .active else { return }
        outputs[index].state = .activating
        send(Messages.setOutput(id))
    }
}

extension PlayState {
    init(_ state: Pb_Remote_EngineState) {
        switch state {
        case .playing: self = .playing
        case .paused: self = .paused
        default: self = .stopped
        }
    }
}
