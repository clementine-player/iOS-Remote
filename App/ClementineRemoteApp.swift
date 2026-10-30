import ClementineKit
import SwiftUI

@main
struct ClementineRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

/// Takes the app's icon's shortcuts, at launch and while running.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcut = options.shortcutItem {
            SceneDelegate.perform(shortcut)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        Self.perform(shortcutItem)
        return true
    }

    /// Play on this phone plays what's on it without connecting, even with Connect automatically on.
    static func perform(_ shortcut: UIApplicationShortcutItem) {
        if shortcut.type == AppModel.playOnPhoneShortcut {
            AppModel.shared?.playWithoutClementine()
        }
    }
}

/// The connect screen until connected, then Clementine's tabs; or the tabs without Clementine, to
/// play what's on this phone.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingKey.appearance) private var appearance = Appearance.system.rawValue

    var body: some View {
        let session = model.session
        ZStack {
            if session.status.isActive || model.isWithoutClementine {
                MainView()
                    .transition(.opacity)
            } else {
                ConnectView()
                    .transition(.opacity)
            }
        }
        .animation(.default, value: session.status.isActive || model.isWithoutClementine)
        .onChange(of: model.songsOnPhone, initial: true) { _, _ in
            model.updateShortcuts()
        }
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
        .onChange(of: session.isPlayingHere) { _, _ in
            model.playingHereChanged()
        }
        .onChange(of: appearance, initial: true) { _, appearance in
            applyAppearance(Appearance(rawValue: appearance) ?? .system)
        }
    }

    /// Overrides every window's style, rather than with `preferredColorScheme`, which leaves an
    /// open sheet in the old style when going back to following the system.
    private func applyAppearance(_ appearance: Appearance) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = appearance.interfaceStyle
            }
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
