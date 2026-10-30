import ClementineKit
import SwiftUI

/// The app's shared state: the session with Clementine, and what the screens share.
@MainActor
@Observable
final class AppModel {
    /// The app's model, for Shortcuts actions that run in the app.
    static weak var shared: AppModel?

    enum Tab: Hashable {
        case queue, library, internet, search, downloads
    }

    let session: RemoteSession
    let settings = Settings()
    let toasts = ToastCenter()
    let network = NetworkMonitor()
    private let sharedState = SharedStateWriter()
    @ObservationIgnored private(set) var library: LibraryModel!
    @ObservationIgnored private(set) var search: SearchModel!
    @ObservationIgnored private(set) var downloads: DownloadsModel!
    /// This phone as somewhere Clementine can play (remote streaming).
    let renderer: Renderer
    /// Clementine's internet services.
    let internet: InternetBrowser
    /// Syncs songs from Clementine to the phone, while connected to it.
    let syncer: Syncer
    /// Plays the songs kept on this phone, without Clementine.
    let phonePlayer = PhonePlayer()
    @ObservationIgnored private var nowPlaying: NowPlaying?
    @ObservationIgnored private var scenePhase = ScenePhase.active

    var selectedTab = Tab.queue
    /// The playlist picked in the queue, if any.
    var selectedPlaylistID: Int32?
    var isPlayerPresented = false
    var isConnectionSheetPresented = false
    var isOutputSheetPresented = false
    var isPlayFromSheetPresented = false

    /// Where the app plays from: Clementine, or the songs kept on this phone.
    enum PlayFrom {
        case clementine, phone
    }

    /// Where the app plays from: this phone from when it starts playing there until Play from
    /// switches back to Clementine.
    private(set) var playFrom = PlayFrom.clementine

    /// Why connecting failed, to explain on the connect screen.
    var connectProblem: ConnectProblem?

    /// Whether the app plays what's on this phone without Clementine, which it isn't connected to:
    /// chosen on the connect screen, or from the app's icon.
    var isWithoutClementine = false

    /// Whether connecting automatically is over for this launch: tried already, or something else
    /// done first.
    private(set) var isAutoConnectOver = false

    /// While connecting automatically, the network name of the Clementine being connected to, to
    /// look for on the network if its saved address doesn't work.
    private var autoConnectName: String?

    init() {
        let session = RemoteSession()
        self.session = session
        renderer = Renderer(playback: AVPlayback(), server: { session.endpoint }) { session.send($0) }
        internet = InternetBrowser { session.send($0) }
        syncer = Syncer(
            session: session, store: TestingFeatures.enabled ? Self.openSyncStore() : nil, folder: Self.syncedFolder)
        // What's kept shows before connecting, for the Clementine last connected.
        syncer.refresh()
        library = LibraryModel(model: self)
        search = SearchModel(model: self)
        downloads = DownloadsModel(model: self)
        let nowPlaying = NowPlaying(model: self)
        self.nowPlaying = nowPlaying
        renderer.onUpdate = { nowPlaying.update() }
        phonePlayer.onUpdate = { nowPlaying.update() }
        syncer.networkAllows = { [network] in network.allows($0) }
        session.addObserver { [renderer, internet] message in
            renderer.handle(message)
            internet.handle(message)
            // The cover comes with the song, which can arrive after the item it's for.
            if message.type == .currentMetainfo {
                nowPlaying.update()
            }
        }
        internet.onAdded = { [weak self] action, result in
            self?.showAdded(action, result: result)
        }
    }

    /// Whether Downloads is On this phone, with the music kept on the phone: when Clementine syncs
    /// songs to it, or something is kept already.
    var isOnThisPhone: Bool {
        session.syncing.supported || !syncer.kept.isEmpty
    }

    /// How many songs are on this phone to play without Clementine, downloaded or kept; 0 without
    /// testing features, until playing on this phone is released.
    var songsOnPhone: Int {
        guard TestingFeatures.enabled else { return 0 }
        return (downloads.onPhone?.count ?? 0) + syncer.kept.reduce(0) { $0 + $1.songs }
    }

    /// Plays what's on this phone without Clementine: stops connecting, if it is, and opens On
    /// this phone. Connected already, it opens On this phone, to play from it.
    func playWithoutClementine() {
        stopAutoConnecting()
        connectProblem = nil
        selectedTab = .downloads
        isPlayerPresented = false
        guard !session.status.isActive else { return }
        if session.status.isConnecting {
            session.disconnect()
        }
        isWithoutClementine = true
    }

    /// Connects to the Clementine last connected to, from playing what's on this phone without it.
    func connectFromPhone() {
        isWithoutClementine = false
        let name = settings.lastServerName
        connect(host: settings.lastHost, name: name.isEmpty ? nil : name)
    }

    /// Offers Play on this phone on the app's icon while there's something to play.
    func updateShortcuts() {
        UIApplication.shared.shortcutItems = songsOnPhone > 0
            ? [UIApplicationShortcutItem(
                type: Self.playOnPhoneShortcut,
                localizedTitle: String(
                    localized: "Play on this phone",
                    comment: "A button in the dialog when connecting fails, and a shortcut on the app's icon: play the music saved on the phone instead of connecting."),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "iphone"))]
            : []
    }

    /// The app's icon's shortcut that plays what's on this phone.
    static let playOnPhoneShortcut = "playOnPhone"

    /// Keeps [rules] on this phone, and says so, naming what's kept: [title].
    func keep(_ rules: [SyncRule], title: String) {
        guard !rules.isEmpty else { return }
        syncer.keep(rules)
        toasts.show(LocalizedStringResource(
            "Keeping \(title) on this phone",
            comment: "Shown for a moment after choosing Keep on this phone; the placeholder is an album, an artist or a playlist."))
    }

    /// What the player and the mini player show and control: songs kept on this phone while the
    /// app plays from there, and they play or are paused there; otherwise Clementine.
    var playback: any PlayerSource {
        isPlayingFromPhone ? PhonePlayerSource(player: phonePlayer) : session
    }

    /// Whether the app plays from this phone, with a song playing or paused there.
    var isPlayingFromPhone: Bool {
        playFrom == .phone && phonePlayer.song != nil
    }

    /// Whether Play from has a choice: Clementine is connected, and a song plays or is paused on
    /// this phone.
    var canChoosePlayFrom: Bool {
        session.status == .connected && phonePlayer.song != nil
    }

    /// Plays [songs] kept on this phone from the one at [index], or all of them at random. Pauses
    /// Clementine, so only one plays.
    func playOnPhone(_ songs: [KeptSong], from index: Int, shuffled: Bool = false) {
        pauseClementine()
        playFrom = .phone
        phonePlayer.play(songs, from: index, shuffled: shuffled)
    }

    /// Switches where the app plays from, pausing the one it leaves; the other stays paused until
    /// it's played. This phone only when a song plays or is paused there.
    func play(from place: PlayFrom) {
        guard place != playFrom, place == .clementine || phonePlayer.song != nil else { return }
        switch place {
        case .phone: pauseClementine()
        case .clementine: phonePlayer.pause()
        }
        playFrom = place
        nowPlaying?.update()
    }

    private func pauseClementine() {
        if session.playState == .playing {
            session.pause()
        }
    }

    /// Where synced songs go: beside the downloaded ones, so the Files app shows them too.
    static let syncedFolder = URL.documentsDirectory.appending(path: "Clementine/Synced", directoryHint: .isDirectory)

    /// The synced songs and their rules, in the app's own files; nil if it can't be opened.
    private static func openSyncStore() -> SyncStore? {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try? SyncStore(url: folder.appending(path: "sync.sqlite"))
    }

    /// Says how putting internet service nodes on the playlist went, where the player doesn't show it.
    private func showAdded(_ action: BrowseAddAction, result: BrowseAddResult) {
        switch result {
        case .added:
            switch action {
            case .append, .unspecified:
                toasts.show("Added to the playlist")
            case .playNext:
                toasts.show("Playing next")
            case .playNow, .replace:
                break
            }
        case .gone:
            toasts.show("That's no longer in Clementine")
        case .notPlayable, .unspecified:
            toasts.show("Clementine can't add that to the playlist")
        }
    }

    /// What to offer Clementine when connecting, so it can play here; nil when that's turned off.
    private var rendererCapabilities: RendererCapabilities? {
        guard settings.renderer else { return nil }
        return Renderer.capabilities(id: settings.rendererID, name: UIDevice.current.name)
    }

    /// Connects to [host], remembering it and [name], Clementine's name on the network if it was
    /// found there.
    func connect(host: String, port: UInt16? = nil, name: String? = nil) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        settings.remember(host: host, name: name)
        stopAutoConnecting()
        connectProblem = nil
        session.connect(
            to: Endpoint(host: host, port: port ?? settings.port), name: name, authCode: settings.lastAuthCode,
            renderer: rendererCapabilities)
    }

    /// With "Connect automatically" on, connects to the Clementine last connected to, once per
    /// launch: at its saved address straight away, as that's quickest when the address hasn't
    /// changed. If it can't be reached there and it was picked from the network, it's looked for
    /// there by name instead ([autoConnect(among:)]).
    func autoConnect() {
        guard settings.autoConnect, !isAutoConnectOver, !settings.lastHost.isEmpty,
              session.status == .disconnected else { return }
        let name = settings.lastServerName
        connect(host: settings.lastHost, name: name.isEmpty ? nil : name)
        autoConnectName = name.isEmpty ? nil : name
    }

    /// While connecting automatically, connects to the Clementine being connected to if it's
    /// among [servers] at another address: once its saved address has failed, or straight away
    /// rather than waiting for the saved address to time out.
    func autoConnect(among servers: [DiscoveredServer]) {
        guard let name = autoConnectName, let server = servers.first(where: { $0.name == name }) else { return }
        switch session.status {
        case .disconnected:
            // Only when the saved address couldn't be reached: not, say, for a wrong auth code.
            guard case .couldNotConnect? = session.closeReason else { return }
        case .connecting where server.host != session.endpoint?.host:
            break
        default:
            return
        }
        connect(host: server.host, port: server.port, name: server.name)
    }

    /// Stops connecting automatically for this launch.
    func stopAutoConnecting() {
        isAutoConnectOver = true
        autoConnectName = nil
    }

    /// Connects again with a new auth code.
    func connect(authCode: Int32) {
        guard let endpoint = session.endpoint else { return }
        settings.lastAuthCode = authCode
        connectProblem = nil
        session.connect(to: endpoint, name: session.hostName, authCode: authCode, renderer: rendererCapabilities)
    }

    /// The session's status changed from [old].
    func statusChanged(from old: RemoteSession.Status) {
        let status = session.status
        if status == .connected, old != .connected {
            network.start()
        }
        // Clementine drops a renderer whose connection goes, and plays on its computer again.
        if status != .connected {
            renderer.reset()
        }
        if status == .downloadingData || status == .connected {
            // Reached Clementine: no need to look for it by name.
            autoConnectName = nil
        }
        guard status == .disconnected, old != .disconnected else { return }
        isPlayerPresented = false
        isConnectionSheetPresented = false
        if autoConnectName != nil, case .couldNotConnect? = session.closeReason {
            // Not at its saved address: wait for it to show up on the network instead.
            return
        }
        autoConnectName = nil
        switch session.closeReason {
        case nil:
            break
        case .disconnected(.wrongAuthCode), .disconnected(.notAuthenticated):
            connectProblem = .authCode
        case .disconnected(.notLocalNetwork):
            connectProblem = .notLocalNetwork
        case .tooManyWrongAuthCodes(let retryAfter):
            connectProblem = .tooManyWrongAuthCodes(retryAfter: retryAfter)
        case .oldProtocol:
            connectProblem = .oldClementine
        case .disconnected:
            if old.isActive {
                toasts.show("Disconnected")
            }
        case .lost where old.isActive:
            connectProblem = .lost
        case .couldNotConnect, .lost, .invalidData:
            connectProblem = .unreachable(network.problem)
        case .localNetworkDenied:
            connectProblem = .localNetworkDenied
        case .requested:
            break
        }
    }

    /// Keeps the connection only while the app is in front, or while Clementine plays here:
    /// Clementine sends the music over it.
    func scenePhaseChanged(to phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .background:
            if !session.isPlayingHere {
                session.suspend()
            }
        case .active:
            session.resume()
        default:
            break
        }
        updateIdleTimer()
    }

    /// Clementine started or stopped playing here. Once it stops, the app in the background lets
    /// the connection go, as it does when not playing.
    func playingHereChanged() {
        if scenePhase == .background, !session.isPlayingHere {
            session.suspend()
        }
    }

    /// The playlist picked in the queue, else the one playing, else the first.
    var selectedPlaylist: Playlist? {
        session.playlists.first { $0.id == selectedPlaylistID } ?? session.activePlaylist ?? session.playlists.first
    }

    /// Tells the widget and Shortcuts what's playing, and where.
    func updateSharedState() {
        sharedState.update(from: self)
    }

    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn && session.status.isActive
    }
}

/// Why the app couldn't connect, or stopped being connected.
enum ConnectProblem: Equatable, Identifiable {
    /// Clementine wants an auth code, or a different one.
    case authCode
    case oldClementine
    case lost
    case unreachable(NetworkMonitor.Problem?)
    /// The address is on this network, and the local network permission was refused.
    case localNetworkDenied
    /// Clementine only accepts connections from its local network, and this phone isn't on it.
    case notLocalNetwork
    /// Too many wrong auth codes have come from this phone, so Clementine won't check one for
    /// this long, if it said.
    case tooManyWrongAuthCodes(retryAfter: Duration?)

    var id: String { String(describing: self) }
}

/// What the player shows and controls: Clementine, or the songs kept on this phone.
@MainActor
protocol PlayerSource {
    var song: Song? { get }
    var playState: PlayState { get }
    /// In seconds.
    var position: Int { get }
    var shuffleMode: ShuffleMode { get }
    var repeatMode: RepeatMode { get }
    /// Whether it's the songs kept on this phone, which have only what the phone can do.
    var isOnPhone: Bool { get }
    func playPause()
    func next()
    func previous()
    func seek(to seconds: Int)
    func stop()
    func cycleShuffle() -> ShuffleMode
    func cycleRepeat() -> RepeatMode
}

extension RemoteSession: PlayerSource {
    var isOnPhone: Bool { false }
}

/// The songs kept on this phone, as the player shows them.
struct PhonePlayerSource: PlayerSource {
    let player: PhonePlayer

    var song: Song? { player.playingSong }
    var playState: PlayState { player.isPlaying ? .playing : .paused }
    var position: Int { Int(player.position) }
    var shuffleMode: ShuffleMode { player.isShuffled ? .all : .off }
    var repeatMode: RepeatMode { player.repeatMode }
    var isOnPhone: Bool { true }
    func playPause() { player.togglePlayPause() }
    func next() { player.next() }
    func previous() { player.previous() }
    func seek(to seconds: Int) { player.seek(to: Double(seconds)) }
    func stop() { player.stop() }

    func cycleShuffle() -> ShuffleMode {
        player.toggleShuffle()
        return shuffleMode
    }

    func cycleRepeat() -> RepeatMode { player.cycleRepeat() }
}
