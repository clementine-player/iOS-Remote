import Foundation
import Testing
@testable import ClementineKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionTests {

    @Test func connectsAndReadsClementinesState() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine(authCode: 42)

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, name: "studio-pc", authCode: 42)
        #expect(session.status == .connecting)
        try await eventually { session.status == .connected }

        let connect = try #require(clementine.received.first)
        #expect(connect.type == .connect)
        #expect(connect.requestConnect.authCode == 42)
        #expect(connect.requestConnect.sendPlaylistSongs)
        #expect(!connect.requestConnect.downloader)

        #expect(session.hostName == "studio-pc")
        #expect(session.clementineVersion == "1.4.1")
        #expect(session.playState == .playing)
        #expect(session.song?.title == "Clair de lune")
        #expect(session.volume == 64)
        #expect(session.playlists.map(\.name) == ["Playlist 1", "Playlist 2"])
        #expect(session.activePlaylistID == 1)
        #expect(session.shuffleMode == .albums)
        #expect(session.repeatMode == .playlist)
        #expect(session.connectedSince != nil)
    }

    @Test func wrongAuthCode() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine(authCode: 42)

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 1)
        try await eventually { session.status == .disconnected }
        #expect(session.closeReason == .disconnected(.wrongAuthCode))
    }

    @Test func nobodyThere() async throws {
        let clementine = try await FakeClementine()
        let endpoint = clementine.endpoint
        clementine.stop()
        try await Task.sleep(for: .milliseconds(100))

        let session = RemoteSession()
        session.connect(to: endpoint, authCode: 0)
        try await eventually { session.status == .disconnected }
        #expect(session.closeReason == .couldNotConnect)
    }

    @Test func sendsCommandsInOrder() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }

        session.playPause()
        session.next()
        session.seek(to: 30)
        session.setVolume(120)
        #expect(session.cycleShuffle() == .off)
        #expect(session.cycleRepeat() == .off)
        try await clementine.waitUntil { $0.received.count == 7 }

        let sent = clementine.received.dropFirst()
        #expect(sent.map(\.type) == [.playpause, .next, .setTrackPosition, .setVolume, .shuffle, .repeat])
        #expect(sent.map(\.requestSetVolume.volume)[3] == 100)
        #expect(session.position == 30)
    }

    @Test func followsClementine() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }

        await clementine.broadcast(RemoteMessage(.pause))
        await clementine.broadcast(RemoteMessage(.updateTrackPosition) { $0.responseUpdateTrackPosition.position = 99 })
        await clementine.broadcast(RemoteMessage(.playlistSongs) {
            $0.responsePlaylistSongs.requestedPlaylist.id = 2
            $0.responsePlaylistSongs.songs = [FakeClementine.song]
        })
        await clementine.broadcast(RemoteMessage(.activePlaylistChanged) { $0.responseActiveChanged.id = 2 })
        try await eventually { session.activePlaylistID == 2 }
        #expect(session.playState == .paused)
        #expect(session.position == 99)
        #expect(session.playlistSongs[2]?.first?.title == "Clair de lune")
    }

    @Test func loadsEachPlaylistsSongsOnce() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }

        session.loadPlaylistSongs()
        #expect(session.playlistsLoading?.total == 2)
        session.loadPlaylistSongs()
        try await clementine.waitUntil { $0.received.count == 3 }
        #expect(clementine.received.dropFirst().map(\.requestPlaylistSongs.id).sorted() == [1, 2])

        for id: Int32 in [1, 2] {
            await clementine.broadcast(RemoteMessage(.playlistSongs) {
                $0.responsePlaylistSongs.requestedPlaylist.id = id
            })
        }
        try await eventually { session.playlistsLoading == nil }
        #expect(session.playlistSongs.count == 2)
    }

    /// Clementine sends a song it can't read (a missing file, say) with no fields set, so with
    /// index 0. Its place in the list is its index in the playlist.
    @Test func numbersPlaylistSongsByTheirPlace() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }

        // FakeClementine.song is the third, index 2.
        await clementine.broadcast(RemoteMessage(.playlistSongs) {
            $0.responsePlaylistSongs.requestedPlaylist.id = 1
            $0.responsePlaylistSongs.songs = [SongMetadata(), SongMetadata(), FakeClementine.song, SongMetadata()]
        })
        try await eventually { session.playlistSongs[1] != nil }
        #expect(session.playlistSongs[1]?.map(\.index) == [0, 1, 2, 3])
        #expect(session.playlistSongs[1]?[2].title == "Clair de lune")
    }

    @Test func reconnectsWhenTheConnectionDrops() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }

        clementine.dropClients()
        try await clementine.waitUntil { $0.received.filter { $0.type == .connect }.count == 2 }
        let reconnect = clementine.received.last { $0.type == .connect }
        #expect(reconnect?.requestConnect.sendPlaylistSongs == false)
        try await eventually { session.status == .connected }
        #expect(session.song?.title == "Clair de lune")
    }

    @Test func reconnectsWhenClementineGoesQuiet() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        var configuration = ClementineConnection.Configuration()
        configuration.keepAliveTimeout = .seconds(1)
        let connection = ClementineConnection(endpoint: clementine.endpoint, authCode: 0, configuration: configuration)
        await connection.start()
        var events: [String] = []
        for await event in connection.events {
            switch event {
            case .connected: events.append("connected")
            case .reconnecting: events.append("reconnecting")
            case .reconnected: events.append("reconnected")
            case .message, .closed: break
            }
            if events.last == "reconnected" { break }
        }
        #expect(events == ["connected", "reconnecting", "reconnected"])
        await connection.disconnect()
    }

    @Test func givesUpWhenClementineIsGone() async throws {
        let clementine = try await FakeClementine()
        clementine.respondLikeClementine()

        var configuration = ClementineConnection.Configuration()
        configuration.reconnectDelay = .milliseconds(10)
        let connection = ClementineConnection(endpoint: clementine.endpoint, authCode: 0, configuration: configuration)
        await connection.start()

        var reason: ClementineConnection.CloseReason?
        var stopped = false
        for await event in connection.events {
            switch event {
            case .message where !stopped:
                // Once Clementine has answered: until then, it never took the connection.
                clementine.stop()
                stopped = true
            case .closed(let why):
                reason = why
            default:
                break
            }
        }
        #expect(reason == .lost)
    }

    @Test func givesUpWhenClementineHangsUpStraightAway() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        // As Clementine does for an address that isn't local, with "Use only local IP addresses".
        clementine.respond { message, client in
            if message.type == .connect { client.cancel() }
        }

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .disconnected }
        #expect(session.closeReason == .couldNotConnect)
        #expect(clementine.clientCount == 1)
    }

    @Test func refusedForNotBeingOnTheLocalNetwork() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respond { message, client in
            guard message.type == .connect else { return }
            try? await client.send(RemoteMessage(.disconnect) {
                $0.responseDisconnect.reasonDisconnect = .notLocalNetwork
            })
            client.cancel()
        }

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .disconnected }
        #expect(session.closeReason == .disconnected(.notLocalNetwork))
        #expect(clementine.clientCount == 1)
    }

    @Test func refusedForTooManyWrongAuthCodes() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respond { message, client in
            guard message.type == .connect else { return }
            try? await client.send(RemoteMessage(.disconnect) {
                $0.responseDisconnect.reasonDisconnect = .tooManyWrongAuthCodes
                $0.responseDisconnect.retryAfterSeconds = 20
            })
            client.cancel()
        }

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .disconnected }
        #expect(session.closeReason == .tooManyWrongAuthCodes(retryAfter: .seconds(20)))
        #expect(clementine.clientCount == 1)
    }

    @Test func waitsAreRoundedUp() {
        let english = Locale(identifier: "en_US")
        #expect(Duration.seconds(10).waitDescription(locale: english) == "10 seconds")
        #expect(Duration.seconds(60).waitDescription(locale: english) == "1 minute")
        #expect(Duration.seconds(61).waitDescription(locale: english) == "2 minutes")
        #expect(Duration.seconds(2560).waitDescription(locale: english) == "43 minutes")
        #expect(Duration.seconds(3600).waitDescription(locale: english) == "1 hour")
    }

    @Test func givesUpWhenClementineKeepsHangingUp() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        var configuration = ClementineConnection.Configuration()
        configuration.reconnectDelay = .milliseconds(10)
        let connection = ClementineConnection(endpoint: clementine.endpoint, authCode: 0, configuration: configuration)
        await connection.start()

        var reason: ClementineConnection.CloseReason?
        var hangingUp = false
        for await event in connection.events {
            switch event {
            case .message where !hangingUp:
                // Once Clementine has answered: until then, it never took the connection.
                clementine.respond { message, client in
                    if message.type == .connect { client.cancel() }
                }
                clementine.dropClients()
                hangingUp = true
            case .closed(let why):
                reason = why
            default:
                break
            }
        }
        #expect(reason == .lost)
        #expect(clementine.clientCount <= 2 + configuration.maxReconnects)
    }

    @Test func createsAPlaylistAndAddsToIt() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }

        clementine.respond { message, client in
            guard message.type == .updatePlaylist else { return }
            try? await client.send(RemoteMessage(.playlists) {
                var first = Pb_Remote_Playlist()
                first.id = 1
                first.name = "Playlist 1"
                first.active = true
                var created = Pb_Remote_Playlist()
                created.id = 9
                created.name = message.requestUpdatePlaylist.newPlaylistName
                $0.responsePlaylists.playlist = [first, created]
            })
        }
        let playlist = await session.createPlaylist(named: "Road trip")
        #expect(playlist == Playlist(id: 9, name: "Road trip"))
        let request = try #require(clementine.received.last { $0.type == .updatePlaylist })
        #expect(request.requestUpdatePlaylist.createNewPlaylist)
        #expect(request.requestUpdatePlaylist.newPlaylistName == "Road trip")

        session.add(urls: ["file:///a.ogg"], to: 9)
        session.add(urls: ["file:///b.ogg"])
        try await clementine.waitUntil { $0.received.filter { $0.type == .insertUrls }.count == 2 }
        let inserts = clementine.received.filter { $0.type == .insertUrls }
        #expect(inserts.map(\.requestInsertUrls.playlistID) == [9, 1])
    }

    @Test func playsAddedSongsOnlyIfNothingIsPlaying() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected && session.playState == .playing }

        session.add(urls: ["file:///a.ogg"], playIfStopped: true)
        await clementine.broadcast(RemoteMessage(.pause))
        try await eventually { session.playState == .paused }
        session.add(urls: ["file:///b.ogg"], playIfStopped: true)
        session.add(songs: [FakeClementine.song], playIfStopped: true)
        session.add(urls: ["file:///c.ogg"])
        try await clementine.waitUntil { $0.received.filter { $0.type == .insertUrls }.count == 4 }
        let inserts = clementine.received.filter { $0.type == .insertUrls }
        #expect(inserts.map(\.requestInsertUrls.playNow) == [false, true, true, false])
    }

    @Test func anOlderClementineDoesntCreatePlaylists() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }
        #expect(await session.createPlaylist(named: "Nope", timeout: .milliseconds(200)) == nil)
    }

    @Test func disconnectSaysGoodbye() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }
        session.disconnect()
        #expect(session.status == .disconnected)
        #expect(session.song == nil)
        try await clementine.waitUntil { $0.received.last?.type == .disconnect }
        #expect(session.closeReason == nil)
    }

    @Test func suspendsAndResumes() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine()

        let session = RemoteSession()
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }
        await clementine.broadcast(RemoteMessage(.playlistSongs) {
            $0.responsePlaylistSongs.requestedPlaylist.id = 1
        })
        try await eventually { session.playlistSongs[1] != nil }

        session.suspend()
        #expect(session.status == .suspended)
        #expect(session.song != nil)
        try await clementine.waitUntil { $0.received.last?.type == .disconnect }

        session.resume()
        try await eventually { session.status == .connected }
        let reconnect = clementine.received.last { $0.type == .connect }
        #expect(reconnect?.requestConnect.sendPlaylistSongs == false)
        // The playlist it had is asked for again.
        try await clementine.waitUntil { $0.received.last?.type == .requestPlaylistSongs }
        #expect(clementine.received.last?.requestPlaylistSongs.id == 1)
    }
}

struct RemoteCommandTests {
    @Test func sendsOneCommandOnAShortConnection() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        try await RemoteCommand.send(RemoteMessage(.next), to: clementine.endpoint, authCode: 7)
        try await clementine.waitUntil { $0.received.count == 3 }
        #expect(clementine.received.map(\.type) == [.connect, .next, .disconnect])
        #expect(clementine.received[0].requestConnect.authCode == 7)
        #expect(!clementine.received[0].requestConnect.sendPlaylistSongs)
    }
}
