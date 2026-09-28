import ClementineKit
import SwiftUI

/// The app's shared state: the session with Clementine, and what the screens share.
@MainActor
@Observable
final class AppModel {
    /// The app's model, for Shortcuts actions that run in the app.
    static weak var shared: AppModel?

    enum Tab: Hashable {
        case queue, library, search, downloads
    }

    let session = RemoteSession()
    let settings = Settings()
    let toasts = ToastCenter()
    let network = NetworkMonitor()
    private let sharedState = SharedStateWriter()
    @ObservationIgnored private(set) var library: LibraryModel!
    @ObservationIgnored private(set) var search: SearchModel!
    @ObservationIgnored private(set) var downloads: DownloadsModel!

    var selectedTab = Tab.queue
    /// The playlist picked in the queue, if any.
    var selectedPlaylistID: Int32?
    var isPlayerPresented = false
    var isConnectionSheetPresented = false

    /// Why connecting failed, to explain on the connect screen.
    var connectProblem: ConnectProblem?

    /// Whether connecting automatically is over for this launch: tried already, or something else
    /// done first.
    private(set) var isAutoConnectOver = false

    /// While connecting automatically, the network name of the Clementine being connected to, to
    /// look for on the network if its saved address doesn't work.
    private var autoConnectName: String?

    init() {
        library = LibraryModel(model: self)
        search = SearchModel(model: self)
        downloads = DownloadsModel(model: self)
    }

    /// Connects to [host], remembering it and [name], Clementine's name on the network if it was
    /// found there.
    func connect(host: String, port: UInt16? = nil, name: String? = nil) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        settings.remember(host: host, name: name)
        stopAutoConnecting()
        connectProblem = nil
        session.connect(to: Endpoint(host: host, port: port ?? settings.port), name: name, authCode: settings.lastAuthCode)
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
        session.connect(to: endpoint, name: session.hostName, authCode: authCode)
    }

    /// The session's status changed from [old].
    func statusChanged(from old: RemoteSession.Status) {
        let status = session.status
        if status == .connected, old != .connected {
            network.start()
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
        case .requested:
            break
        }
    }

    /// Keeps the connection only while the app is in front.
    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            session.suspend()
        case .active:
            session.resume()
        default:
            break
        }
        updateIdleTimer()
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

    var id: String { String(describing: self) }
}
