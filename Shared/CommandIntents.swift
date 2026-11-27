import AppIntents
import ClementineKit
import WidgetKit

/// Sends a command to the Clementine the app last connected to.
protocol CommandIntent: AppIntent {
    var message: RemoteMessage { get }
}

extension CommandIntent {
    func perform() async throws -> some IntentResult {
        let state = SharedState.load()
        guard let endpoint = state.endpoint else {
            throw CommandError.noClementine
        }
        do {
            try await RemoteCommand.send(message, to: endpoint, authCode: state.authCode)
        } catch {
            throw Self.mapError(error)
        }
        return .result()
    }

    /// Maps server-side disconnect causes separately so auth and local-network rejections aren't
    /// reported as generic unreachability.
    static func mapError(_ error: Error) -> CommandError {
        guard let remoteError = error as? RemoteCommandError else { return .unreachable }
        switch remoteError {
        case .disconnected(.wrongAuthCode), .disconnected(.notAuthenticated):
            return .wrongAuthCode
        case .disconnected(.notLocalNetwork):
            return .notLocalNetwork
        case .disconnected:
            return .refused
        }
    }
}

enum CommandError: Error, CustomLocalizedStringResourceConvertible {
    case noClementine
    case unreachable
    case wrongAuthCode
    case notLocalNetwork
    case refused

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noClementine: "Connect to Clementine in Clementine Remote first."
        case .unreachable: "Couldn't reach Clementine."
        case .wrongAuthCode:
            LocalizedStringResource(
                "Enter the auth code shown in Clementine's Network Remote settings.",
                comment: "Shortcut and widget error when Clementine rejects the saved auth code.")
        case .notLocalNetwork:
            LocalizedStringResource(
                "Clementine only accepts connections from its local network.",
                comment: "Shortcut and widget error when Clementine refuses connections outside its local network.")
        case .refused:
            LocalizedStringResource(
                "Clementine closed the connection.",
                comment: "Shortcut and widget error when Clementine rejects or closes a control command connection.")
        }
    }
}

struct PlayIntent: CommandIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Starts Clementine playing.")
    var message: RemoteMessage { RemoteMessage(.play) }
}

struct PauseIntent: CommandIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses Clementine.")
    var message: RemoteMessage { RemoteMessage(.pause) }
}

struct PlayPauseIntent: CommandIntent {
    static let title: LocalizedStringResource = "Play or pause"
    static let description = IntentDescription("Plays Clementine if it's paused, and pauses it if it's playing.")
    var message: RemoteMessage { RemoteMessage(.playpause) }

    func perform() async throws -> some IntentResult {
        let state = SharedState.load()
        guard let endpoint = state.endpoint else { throw CommandError.noClementine }
        do {
            try await RemoteCommand.send(message, to: endpoint, authCode: state.authCode)
        } catch {
            throw Self.mapError(error)
        }
        // Show the change at once in the widget.
        var changed = state
        changed.isPlaying.toggle()
        changed.save()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct NextIntent: CommandIntent {
    static let title: LocalizedStringResource = "Next song"
    static let description = IntentDescription("Skips to Clementine's next song.")
    var message: RemoteMessage { RemoteMessage(.next) }
}

struct StopIntent: CommandIntent {
    static let title: LocalizedStringResource = "Stop"
    static let description = IntentDescription("Stops Clementine.")
    var message: RemoteMessage { RemoteMessage(.stop) }
}
