import AppIntents
import ClementineKit
import SwiftUI
import WidgetKit

/// Opens the app and connects to the Clementine it last connected to.
struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Clementine"
    static let description = IntentDescription("Opens Clementine Remote and connects to the last Clementine.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared, !model.settings.lastHost.isEmpty else {
            throw CommandError.noClementine
        }
        if model.session.status == .disconnected {
            let name = model.settings.lastServerName
            model.connect(host: model.settings.lastHost, name: name.isEmpty ? nil : name)
        }
        return .result()
    }
}

/// Disconnects the app from Clementine.
struct DisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect from Clementine"
    static let description = IntentDescription("Disconnects Clementine Remote from Clementine.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.session.disconnect()
        return .result()
    }
}

struct ClementineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: ["Play or pause \(.applicationName)", "Pause \(.applicationName)"],
            shortTitle: "Play or pause",
            systemImageName: "playpause.fill")
        AppShortcut(
            intent: NextIntent(),
            phrases: ["Skip the song in \(.applicationName)", "Next song in \(.applicationName)"],
            shortTitle: "Next song",
            systemImageName: "forward.end.fill")
        AppShortcut(
            intent: ConnectIntent(),
            phrases: ["Connect \(.applicationName)"],
            shortTitle: "Connect",
            systemImageName: "desktopcomputer")
    }
}

/// Keeps what the widget and Shortcuts know up to date.
@MainActor
final class SharedStateWriter {
    private var last = SharedState.load()

    func update(from model: AppModel) {
        let session = model.session
        var state = last
        if let endpoint = session.endpoint {
            state.host = endpoint.host
            state.port = endpoint.port
            state.authCode = session.authCode
        }
        if session.status == .connected {
            state.title = session.song?.title ?? ""
            state.artist = session.song?.artist ?? ""
            state.isPlaying = session.playState == .playing
        }
        guard state != last else { return }
        last = state
        state.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
