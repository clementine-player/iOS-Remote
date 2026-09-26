import Foundation
import Network
import Synchronization
@testable import ClementineKit

/// A stand-in for Clementine's network remote, on a local port.
final class FakeClementine: Sendable {
    /// Answers a message from a client, by sending messages on its channel.
    typealias Responder = @Sendable (RemoteMessage, MessageChannel) async -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-clementine")
    private let state = Mutex((received: [RemoteMessage](), clients: [MessageChannel](), responder: Responder?.none))

    /// Listens on a free port.
    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = AsyncStream<Void>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        for await _ in ready.stream { break }
    }

    var endpoint: Endpoint {
        Endpoint(host: "127.0.0.1", port: listener.port!.rawValue)
    }

    var received: [RemoteMessage] {
        state.withLock { $0.received }
    }

    var clientCount: Int {
        state.withLock { $0.clients.count }
    }

    /// Answers each message a client sends with [responder].
    func respond(_ responder: @escaping Responder) {
        state.withLock { $0.responder = responder }
    }

    /// Answers CONNECT as Clementine does: info, the current song, volume, playlists, modes, and
    /// first data sent.
    func respondLikeClementine(authCode: Int32 = 0, extra: [RemoteMessage] = []) {
        respond { message, client in
            guard message.type == .connect else { return }
            if message.requestConnect.authCode != authCode {
                try? await client.send(RemoteMessage(.disconnect) {
                    $0.responseDisconnect.reasonDisconnect = .wrongAuthCode
                })
                return
            }
            for reply in FakeClementine.firstData + extra {
                try? await client.send(reply)
            }
        }
    }

    /// Sends [message] to every client.
    func broadcast(_ message: RemoteMessage) async {
        for client in state.withLock({ $0.clients }) {
            try? await client.send(message)
        }
    }

    /// Drops every client, as if the network went away.
    func dropClients() {
        for client in state.withLock({ $0.clients }) {
            client.cancel()
        }
    }

    func stop() {
        dropClients()
        listener.cancel()
    }

    /// Waits until [condition] holds, or fails after [timeout].
    func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable (FakeClementine) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(self) {
            guard ContinuousClock.now < deadline else { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = MessageChannel(accepted: connection)
        state.withLock { $0.clients.append(client) }
        Task {
            while let message = try? await client.receive() {
                let responder = state.withLock { state in
                    state.received.append(message)
                    return state.responder
                }
                await responder?(message, client)
            }
        }
    }

    static let song: SongMetadata = {
        var song = SongMetadata()
        song.id = 7
        song.index = 2
        song.title = "Clair de lune"
        song.artist = "Claude Debussy"
        song.album = "Suite bergamasque"
        song.length = 300
        song.prettyLength = "5:00"
        song.isLocal = true
        song.url = "file:///music/clair.ogg"
        return song
    }()

    static var firstData: [RemoteMessage] {
        [
            RemoteMessage(.info) {
                $0.responseClementineInfo.version = "1.4.1"
                $0.responseClementineInfo.state = .playing
            },
            RemoteMessage(.currentMetainfo) { $0.responseCurrentMetadata.songMetadata = song },
            RemoteMessage(.setVolume) { $0.requestSetVolume.volume = 64 },
            RemoteMessage(.playlists) {
                var first = Pb_Remote_Playlist()
                first.id = 1
                first.name = "Playlist 1"
                first.active = true
                var second = Pb_Remote_Playlist()
                second.id = 2
                second.name = "Playlist 2"
                $0.responsePlaylists.playlist = [first, second]
            },
            RemoteMessage(.shuffle) { $0.shuffle.shuffleMode = .shuffleAlbums },
            RemoteMessage(.repeat) { $0.repeat.repeatMode = .repeatPlaylist },
            RemoteMessage(.firstDataSentComplete),
        ]
    }
}

struct TimeoutError: Error {}

/// Waits until [condition] holds on the main actor, or fails after [timeout].
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
