import Foundation
import Testing
@testable import ClementineKit

/// Updating what's kept on the phone in the background.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BackgroundSyncTests {
    /// Settings for a phone that last synced with SyncerTests.server, at [endpoint].
    static func settings(_ endpoint: Endpoint) -> Settings {
        let settings = Settings(suiteName: "BackgroundSyncTests-\(UUID().uuidString)")
        settings.syncServerID = SyncerTests.server
        settings.lastHost = endpoint.host
        settings.store.set(Int(endpoint.port), forKey: SettingKey.port)
        return settings
    }

    /// Clementine that says it's [serverID], and answers each manifest request with no songs.
    static func clementine(serverID: String = SyncerTests.server) async throws -> FakeClementine {
        let clementine = try await FakeClementine()
        clementine.respond { message, client in
            switch message.type {
            case .connect:
                for reply in [SyncerTests.syncingInfo(serverID: serverID)] + FakeClementine.firstData.dropFirst() {
                    try? await client.send(reply)
                }
            case .requestSyncManifest:
                try? await client.send(SyncerTests.manifest(message.requestSyncManifest.sourceID))
            default:
                break
            }
        }
        return clementine
    }

    static func playlistRule(_ policy: RefreshPolicy = .onConnect) -> SyncRule {
        SyncRule(serverID: SyncerTests.server, sourceID: "playlist/1", title: "Playlist 1", kind: .playlist, refreshPolicy: policy)
    }

    @Test func neverRunsInLowDataMode() {
        #expect(BackgroundSync.allows(.wifiOnly, expensive: false, constrained: false))
        #expect(!BackgroundSync.allows(.wifiOnly, expensive: true, constrained: false))
        #expect(BackgroundSync.allows(.any, expensive: true, constrained: false))
        #expect(!BackgroundSync.allows(.any, expensive: false, constrained: true))
        #expect(!BackgroundSync.allows(.wifiOnly, expensive: false, constrained: true))
    }

    @Test func syncsRulesUpdatedEachTimeAndThoseYetToGetTheirSongs() {
        var album = Self.playlistRule(.never)
        #expect(BackgroundSync.hasRulesToSync([album]))
        album.lastSynced = .now
        #expect(!BackgroundSync.hasRulesToSync([album]))
        #expect(BackgroundSync.hasRulesToSync([album, Self.playlistRule()]))
        #expect(!BackgroundSync.hasRulesToSync([]))
    }

    @Test func connectsSyncsAndDisconnects() async throws {
        let clementine = try await Self.clementine()
        defer { clementine.stop() }
        let store = try SyncStore(url: nil)
        let rule = try await store.addRule(Self.playlistRule())
        let settings = Self.settings(clementine.endpoint)
        let session = RemoteSession()
        let syncer = Syncer(session: session, store: store, folder: FileManager.default.temporaryDirectory, settings: settings)

        #expect(await BackgroundSync.run(session: session, syncer: syncer, settings: settings))
        #expect(syncer.status.results[rule] == .synced(songs: 0, downloaded: 0, skipped: 0))
        #expect(session.status == .disconnected)
        #expect(syncer.onlyServerID == nil)
        // Only what syncing needs: not every playlist's songs.
        let connect = try #require(clementine.received.first { $0.type == .connect })
        #expect(!connect.requestConnect.sendPlaylistSongs)
    }

    @Test func leavesAnotherClementineAtTheSameAddressAlone() async throws {
        let clementine = try await Self.clementine(serverID: "another")
        defer { clementine.stop() }
        let store = try SyncStore(url: nil)
        _ = try await store.addRule(Self.playlistRule())
        let settings = Self.settings(clementine.endpoint)
        let session = RemoteSession()
        let syncer = Syncer(session: session, store: store, folder: FileManager.default.temporaryDirectory, settings: settings)

        #expect(!(await BackgroundSync.run(session: session, syncer: syncer, settings: settings)))
        #expect(!clementine.received.contains { $0.type == .requestSyncManifest })
        #expect(settings.syncServerID == SyncerTests.server)
        #expect(session.status == .disconnected)
    }

    @Test func givesUpWhenClementineIsntThere() async throws {
        let clementine = try await FakeClementine()
        let endpoint = clementine.endpoint
        clementine.stop()
        let store = try SyncStore(url: nil)
        _ = try await store.addRule(Self.playlistRule())
        let settings = Self.settings(endpoint)
        let session = RemoteSession()
        let syncer = Syncer(session: session, store: store, folder: FileManager.default.temporaryDirectory, settings: settings)

        #expect(!(await BackgroundSync.run(session: session, syncer: syncer, settings: settings)))
        #expect(session.status == .disconnected)
    }

    @Test func doesntConnectWithNothingToSyncOrWithTheSettingOff() async throws {
        let clementine = try await Self.clementine()
        defer { clementine.stop() }
        let store = try SyncStore(url: nil)
        var album = Self.playlistRule(.never)
        album.lastSynced = .now
        _ = try await store.addRule(album)
        let settings = Self.settings(clementine.endpoint)
        let session = RemoteSession()
        let syncer = Syncer(session: session, store: store, folder: FileManager.default.temporaryDirectory, settings: settings)

        #expect(!(await BackgroundSync.run(session: session, syncer: syncer, settings: settings)))
        var playlist = Self.playlistRule()
        playlist.sourceID = "playlist/2"
        _ = try await store.addRule(playlist)
        settings.store.set(false, forKey: SettingKey.backgroundSync)
        #expect(!(await BackgroundSync.run(session: session, syncer: syncer, settings: settings)))
        #expect(session.status == .disconnected)
        #expect(clementine.clientCount == 0)
    }

    @Test func syncsOverTheAppsConnection() async throws {
        let clementine = try await Self.clementine()
        defer { clementine.stop() }
        let store = try SyncStore(url: nil)
        let rule = try await store.addRule(Self.playlistRule())
        let settings = Self.settings(clementine.endpoint)
        let session = RemoteSession()
        let syncer = Syncer(session: session, store: store, folder: FileManager.default.temporaryDirectory, settings: settings)
        session.connect(to: clementine.endpoint, authCode: 0)
        try await eventually { session.status == .connected }
        await syncer.finish()

        #expect(await BackgroundSync.run(session: session, syncer: syncer, settings: settings))
        #expect(syncer.status.results[rule] != nil)
        // The app's connection stays.
        #expect(session.status == .connected)
        session.disconnect()
    }

    @Test func reconnectsASuspendedSessionWithoutOfferingThePhoneToPlayOn() async throws {
        let clementine = try await Self.clementine()
        defer { clementine.stop() }
        let store = try SyncStore(url: nil)
        let rule = try await store.addRule(Self.playlistRule())
        let settings = Self.settings(clementine.endpoint)
        let session = RemoteSession()
        let syncer = Syncer(session: session, store: store, folder: FileManager.default.temporaryDirectory, settings: settings)
        session.connect(
            to: clementine.endpoint, authCode: 0, renderer: Renderer.capabilities(id: "phone", name: "iPhone"))
        try await eventually { session.status == .connected }
        await syncer.finish()
        session.suspend()

        #expect(await BackgroundSync.run(session: session, syncer: syncer, settings: settings))
        #expect(syncer.status.results[rule] != nil)
        #expect(session.status == .suspended)
        let connects = clementine.received.filter { $0.type == .connect }
        #expect(connects.count == 2)
        #expect(connects.first?.requestConnect.hasRenderer == true)
        #expect(connects.last?.requestConnect.hasRenderer == false)
        // The app offers it again when it next resumes.
        #expect(session.renderer != nil)
    }
}
