import ClementineKit
import SwiftUI

@main
struct ClementineRemoteApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        AppModel.shared = model
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.session)
                .tint(Palette.primary)
        }
    }
}

/// The connect screen until connected, then Clementine's tabs.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let session = model.session
        ZStack {
            if session.status.isActive {
                MainView()
                    .transition(.opacity)
            } else {
                ConnectView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: session.status.isActive)
        .toasts(model.toasts)
        .onChange(of: session.status) { old, _ in
            model.statusChanged(from: old)
            model.updateIdleTimer()
        }
        .onChange(of: SharedSnapshot(session: session)) { _, _ in
            model.updateSharedState()
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
    }
}

/// What the widget shows, to notice when it changes.
private struct SharedSnapshot: Equatable {
    let status: RemoteSession.Status
    let title: String?
    let artist: String?
    let playing: Bool

    @MainActor
    init(session: RemoteSession) {
        status = session.status
        title = session.song?.title
        artist = session.song?.artist
        playing = session.playState == .playing
    }
}
