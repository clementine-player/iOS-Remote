import Foundation
import Network
import Synchronization
import Testing
@testable import ClementineKit

/// Syncing with the connected Clementine.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SyncerTests {
    nonisolated static let server = "4f1c2d6e-8a0b-4c8e-9b7a-2e3f5d6c7b8a"

    /// Clementine that syncs, and lets the phone download songs.
    nonisolated static func syncingInfo(serverID: String = server, allowDownloads: Bool = true) -> RemoteMessage {
        RemoteMessage(.info) {
            $0.responseClementineInfo.version = "1.4.4"
            $0.responseClementineInfo.features = [.sync]
            $0.responseClementineInfo.serverID = serverID
            $0.responseClementineInfo.allowDownloads = allowDownloads
        }
    }

    nonisolated static func request(_ sourceID: String) -> Pb_Remote_RequestSyncManifest {
        var request = Pb_Remote_RequestSyncManifest()
        request.sourceID = sourceID
        return request
    }

    nonisolated static func manifest(_ sourceID: String, items: [Pb_Remote_SyncItem] = []) -> RemoteMessage {
        RemoteMessage(.syncManifest) {
            $0.responseSyncManifest.sourceID = sourceID
            $0.responseSyncManifest.state = .ready
            $0.responseSyncManifest.items = items
        }
    }

    /// What was sent to Clementine.
    @MainActor
    final class Sent {
        var messages: [RemoteMessage] = []
    }

    @Test func theSessionSaysWhetherClementineSyncs() async throws {
        let session = RemoteSession()
        session.apply(Self.syncingInfo())
        #expect(session.syncing == Syncing(supported: true, serverID: Self.server, downloadsAllowed: true))
        #expect(session.syncing.available)

        session.apply(Self.syncingInfo(allowDownloads: false))
        #expect(session.syncing.supported)
        #expect(!session.syncing.available)

        // A Clementine without a server id can't keep the phone's songs apart from another's.
        session.apply(Self.syncingInfo(serverID: ""))
        #expect(!session.syncing.supported)

        session.apply(FakeClementine.firstData[0])
        #expect(session.syncing == Syncing())
    }

    @Test func waitsForTheManifestOfItsOwnSource() async throws {
        let manifests = SyncManifests()
        let sent = Sent()
        let answer = Task {
            try await manifests.ask(Self.request("playlist/1"), send: { sent.messages.append($0) }, timeout: .seconds(10))
        }
        try await eventually { sent.messages.count == 1 }
        #expect(sent.messages[0].type == .requestSyncManifest)
        #expect(sent.messages[0].requestSyncManifest.sourceID == "playlist/1")

        manifests.handle(Self.manifest("playlist/2"))
        var item = Pb_Remote_SyncItem()
        item.itemKey = "a"
        manifests.handle(Self.manifest("playlist/1", items: [item]))
        let manifest = try await answer.value
        #expect(manifest.sourceID == "playlist/1")
        #expect(manifest.items.map(\.itemKey) == ["a"])
    }

    @Test func givesUpWhenClementineDoesntAnswer() async throws {
        let manifests = SyncManifests()
        await #expect(throws: SyncConnectionError.noAnswer("playlist/1")) {
            try await manifests.ask(Self.request("playlist/1"), send: { _ in }, timeout: .milliseconds(100))
        }
    }

    @Test func fetchesSongsFromClementinesHTTPServer() async throws {
        let http = try await FakeHTTPServer(body: Data("song".utf8))
        defer { http.stop() }
        let connection = ClementineSyncConnection(
            serverID: Self.server, manifests: SyncManifests(), send: { _ in },
            server: { Endpoint(host: "127.0.0.1", port: http.port) })
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }

        try await connection.download("/d/token/1", to: file)
        #expect(try Data(contentsOf: file) == Data("song".utf8))
        #expect(http.paths == ["/d/token/1"])
    }

    @Test func aRefusedSongFails() async throws {
        let http = try await FakeHTTPServer(status: 404, body: Data())
        defer { http.stop() }
        let connection = ClementineSyncConnection(
            serverID: Self.server, manifests: SyncManifests(), send: { _ in },
            server: { Endpoint(host: "127.0.0.1", port: http.port) })
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        await #expect(throws: SyncConnectionError.status(404)) {
            try await connection.download("/d/token/1", to: file)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func syncsWhenClementineConnects() async throws {
        let http = try await FakeHTTPServer(body: Data("song".utf8))
        defer { http.stop() }
        var item = Pb_Remote_SyncItem()
        item.itemKey = "a"
        item.version = "1"
        item.url = "http://127.0.0.1:\(http.port)/d/token/1"
        item.mimeType = "audio/flac"
        item.delivery = .original
        item.song.title = "Debaser"
        item.song.artist = "Pixies"
        item.song.album = "Doolittle"
        item.song.track = 1
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respond { [item] message, client in
            switch message.type {
            case .connect:
                for reply in FakeClementine.firstData + [SyncerTests.syncingInfo()] {
                    try? await client.send(reply)
                }
            case .requestSyncManifest:
                try? await client.send(SyncerTests.manifest(message.requestSyncManifest.sourceID, items: [item]))
            default:
                break
            }
        }

        let store = try SyncStore(url: nil)
        let rule = try await store.addRule(
            SyncRule(serverID: Self.server, sourceID: "playlist/1", title: "Playlist 1", kind: .playlist, refreshPolicy: .onConnect))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = RemoteSession()
        let syncer = Syncer(session: session, store: store, folder: folder)
        session.connect(to: clementine.endpoint, authCode: 0)

        try await eventually { syncer.status.results[rule] != nil }
        await syncer.finish()
        #expect(syncer.status.results[rule] == .synced(songs: 1, downloaded: 1, skipped: 0))
        #expect(!syncer.status.running)
        #expect(try Data(contentsOf: folder.appending(path: "Pixies/Doolittle/01 Debaser.flac")) == Data("song".utf8))
        session.disconnect()
    }

    @Test func doesntSyncWhenClementineWontLetThePhoneDownload() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine(extra: [Self.syncingInfo(allowDownloads: false)])
        let store = try SyncStore(url: nil)
        _ = try await store.addRule(
            SyncRule(serverID: Self.server, sourceID: "playlist/1", title: "Playlist 1", kind: .playlist, refreshPolicy: .onConnect))
        let session = RemoteSession()
        let syncer = Syncer(session: session, store: store, folder: FileManager.default.temporaryDirectory)
        session.connect(to: clementine.endpoint, authCode: 0)

        try await eventually { session.syncing.supported }
        syncer.syncNow()
        await syncer.finish()
        #expect(syncer.status == Syncer.Status())
        #expect(!clementine.received.contains { $0.type == .requestSyncManifest })
        session.disconnect()
    }
}

/// Answers every HTTP request with [status] and [body], on a local port.
final class FakeHTTPServer: Sendable {
    private let listener: NWListener
    private let requested = Mutex([String]())

    init(status: Int = 200, body: Data) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = AsyncStream<Void>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                // "GET /path HTTP/1.1": the path.
                let line = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ")
                self?.requested.withLock { $0.append(line.count > 1 ? String(line[1]) : "") }
                var response = Data(
                    "HTTP/1.1 \(status) Status\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        for await _ in ready.stream { break }
    }

    var port: UInt16 { listener.port!.rawValue }

    /// The paths asked for so far.
    var paths: [String] { requested.withLock { $0 } }

    func stop() {
        listener.cancel()
    }
}
