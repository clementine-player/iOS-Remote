import Foundation

public enum RemoteCommandError: Error, Sendable, Equatable {
    case disconnected(DisconnectReason?)
}

/// Sends one command to Clementine over a short connection of its own, for Shortcuts and the
/// widget, which run without the app's connection.
public enum RemoteCommand {
    public static func send(_ message: RemoteMessage, to endpoint: Endpoint, authCode: Int32) async throws {
        let channel = MessageChannel(endpoint: endpoint)
        defer { channel.cancel() }
        try await channel.open()
        try await channel.send(Messages.connect(authCode: authCode, sendPlaylistSongs: false, downloader: false))
        // Wait for Clementine's INFO (authenticated) or DISCONNECT (wrong auth code, local-only, etc.)
        // before sending the command.
        while true {
            let reply = try await channel.receive(timeout: .seconds(5))
            switch reply.type {
            case .info:
                try await channel.send(message)
                // Send FIN with .disconnect and briefly wait for EOF so Clementine processes the
                // command before defer cancels the socket with a TCP RST.
                try await channel.send(RemoteMessage(.disconnect), final: true)
                await drainUntilClosed(channel, timeout: .milliseconds(500))
                return
            case .disconnect:
                let reason = reply.responseDisconnect.hasReasonDisconnect
                    ? reply.responseDisconnect.reasonDisconnect : nil
                throw RemoteCommandError.disconnected(reason)
            default:
                continue
            }
        }
    }

    private static func drainUntilClosed(_ channel: MessageChannel, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = deadline - .now
            guard remaining > .zero else { return }
            do {
                _ = try await channel.receive(timeout: remaining)
            } catch {
                return
            }
        }
    }
}
