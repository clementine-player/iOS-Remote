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
    var isPlayerPresented = false
    var isConnectionSheetPresented = false

    /// Why connecting failed, to explain on the connect screen.
    var connectProblem: ConnectProblem?

    init() {
        library = LibraryModel(model: self)
        search = SearchModel(model: self)
        downloads = DownloadsModel(model: self)
    }

    /// Connects to [host], remembering it.
    func connect(host: String, port: UInt16? = nil, name: String? = nil) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        settings.remember(host: host)
        connectProblem = nil
        session.connect(to: Endpoint(host: host, port: port ?? settings.port), name: name, authCode: settings.lastAuthCode)
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
        guard status == .disconnected, old != .disconnected else { return }
        isPlayerPresented = false
        isConnectionSheetPresented = false
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
