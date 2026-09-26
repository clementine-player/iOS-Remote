import Foundation

/// Sends one command to Clementine over a short connection of its own, for Shortcuts and the
/// widget, which run without the app's connection.
public enum RemoteCommand {
    public static func send(_ message: RemoteMessage, to endpoint: Endpoint, authCode: Int32) async throws {
        let channel = MessageChannel(endpoint: endpoint)
        defer { channel.cancel() }
        try await channel.open()
        try await channel.send(Messages.connect(authCode: authCode, sendPlaylistSongs: false, downloader: false))
        try await channel.send(message)
        try await channel.send(RemoteMessage(.disconnect))
    }
}
