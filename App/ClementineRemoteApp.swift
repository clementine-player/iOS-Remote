import ClementineKit
import SwiftUI

@main
struct ClementineRemoteApp: App {
    @State private var model = AppModel()

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
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
    }
}
