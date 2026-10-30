import Foundation
import Testing
@testable import ClementineKit

/// Syncing a Clementine's rules to the phone.
struct SyncEngineTests {
    static let server = "4f1c2d6e-8a0b-4c8e-9b7a-2e3f5d6c7b8a"
    static let synced = Date(timeIntervalSince1970: 1_700_000_000)

    /// Clementine's side: manifests by source id, and the files its /d/ URLs serve.
    actor Clementine: SyncConnection {
        nonisolated let serverID = SyncEngineTests.server
        var manifests: [String: Pb_Remote_ResponseSyncManifest] = [:]
        var files: [String: Data] = [:]
        var requests: [Pb_Remote_RequestSyncManifest] = []
        var opened: [String] = []

        func manifest(_ request: Pb_Remote_RequestSyncManifest) throws -> Pb_Remote_ResponseSyncManifest {
            requests.append(request)
            guard let manifest = manifests[request.sourceID] else { throw URLError(.notConnectedToInternet) }
            return manifest
        }

        func download(_ path: String, to file: URL) throws {
            opened.append(path)
            guard let data = files[path] else { throw URLError(.fileDoesNotExist) }
            try data.write(to: file)
        }

        func serve(_ sourceID: String, _ items: [Pb_Remote_SyncItem], skipped: Int32 = 0) {
            var manifest = Pb_Remote_ResponseSyncManifest()
            manifest.sourceID = sourceID
            manifest.state = .ready
            manifest.items = items
            manifest.skipped = skipped
            manifests[sourceID] = manifest
        }

        func answer(_ sourceID: String, state: Pb_Remote_SyncManifestState, message: String = "") {
            var manifest = Pb_Remote_ResponseSyncManifest()
            manifest.state = state
            manifest.message = message
            manifests[sourceID] = manifest
        }

        func put(_ path: String, _ data: Data) { files[path] = data }
        func remove(_ path: String) { files[path] = nil }
        func clearOpened() { opened = [] }
        func clearRequests() { requests = [] }
    }

    let store: SyncStore
    let folder: URL
    let clementine = Clementine()
    let engine: SyncEngine

    init() throws {
        store = try SyncStore(url: nil)
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        engine = SyncEngine(store: store, folder: folder, supportedFormats: ["audio/flac"], now: { Self.synced })
    }

    func rule(_ sourceID: String, limitItems: Int = 0, refreshPolicy: RefreshPolicy = .onConnect) async throws -> Int64 {
        try await store.addRule(
            SyncRule(
                serverID: Self.server, sourceID: sourceID, title: sourceID, kind: .album, refreshPolicy: refreshPolicy,
                limitItems: limitItems))
    }

    func song(_ key: String, version: String = "1", title: String? = nil, track: Int32 = 1) async -> Pb_Remote_SyncItem {
        let url = "/d/token/\(key)-\(version)"
        await clementine.put(url, Data("\(key) \(version)".utf8))
        var item = Pb_Remote_SyncItem()
        item.itemKey = key
        item.version = version
        item.url = url
        item.mimeType = "audio/flac"
        item.sizeBytes = 100
        item.delivery = .original
        item.song.title = title ?? key
        item.song.artist = "Pixies"
        item.song.album = "Doolittle"
        item.song.track = track
        return item
    }

    /// The files in the synced songs' folder, by path, leaving out hidden ones.
    func files() throws -> [String: String] {
        var files: [String: String] = [:]
        guard let paths = FileManager.default.enumerator(atPath: folder.path) else { return files }
        for case let path as String in paths {
            let url = folder.appending(path: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !url.lastPathComponent.hasPrefix(".") else { continue }
            files[path] = try String(decoding: Data(contentsOf: url), as: UTF8.self)
        }
        return files
    }

    @Test func downloadsARulesSongs() async throws {
        let album = try await rule("library/album/Pixies/Doolittle", limitItems: 20)
        await clementine.serve(
            "library/album/Pixies/Doolittle",
            [await song("a", title: "Debaser"), await song("b", title: "Tame", track: 3)], skipped: 1)

        let result = try await engine.sync(clementine)

        #expect(result.rules[album] == .synced(songs: 2, downloaded: 2, skipped: 1))
        #expect(try await store.ruleItems(ruleID: album).map(\.itemKey) == ["a", "b"])
        #expect(try files() == [
            "Pixies/Doolittle/01 Debaser.flac": "a 1",
            "Pixies/Doolittle/03 Tame.flac": "b 1",
        ])
        #expect(try await store.rule(id: album)?.lastSynced == Self.synced)

        let request = try #require(await clementine.requests.first)
        #expect(request.limitItems == 20)
        #expect(request.supportedFormats.map(\.mimeType) == ["audio/flac"])

        let item = try #require(try await store.item(serverID: Self.server, itemKey: "a"))
        #expect(try SongMetadata(serializedBytes: item.metadata).title == "Debaser")
        #expect(item.path == "Pixies/Doolittle/01 Debaser.flac")
    }

    @Test func downloadsOnlyWhatsNewOrChanged() async throws {
        _ = try await rule("playlist/1")
        await clementine.serve("playlist/1", [await song("a"), await song("b")])
        _ = try await engine.sync(clementine)
        await clementine.clearOpened()

        await clementine.serve("playlist/1", [await song("a"), await song("b", version: "2")])
        _ = try await engine.sync(clementine)

        #expect(await clementine.opened == ["/d/token/b-2"])
        #expect(try await store.item(serverID: Self.server, itemKey: "b")?.version == "2")
        #expect(try files().count == 2)
        #expect(try files()["Pixies/Doolittle/01 b.flac"] == "b 2")
    }

    /// What a sync says about how far it has got.
    actor Progress {
        var heard: [(ruleID: Int64, done: Int, total: Int)] = []
        func hear(_ ruleID: Int64, _ progress: SyncProgress) { heard.append((ruleID, progress.done, progress.total)) }
        func clear() { heard = [] }
    }

    @Test func saysHowManySongsItHasDownloaded() async throws {
        let progress = Progress()
        let engine = SyncEngine(
            store: store, folder: folder, supportedFormats: ["audio/flac"],
            progress: { await progress.hear($0, $1) })
        let playlist = try await rule("playlist/1")
        await clementine.serve("playlist/1", [await song("a")])
        _ = try await engine.sync(clementine)
        await progress.clear()

        // Only the songs it has to download count.
        await clementine.serve("playlist/1", [await song("a"), await song("b"), await song("c")])
        _ = try await engine.sync(clementine)
        #expect(await progress.heard.map { [$0.ruleID, Int64($0.done), Int64($0.total)] }
            == [[playlist, 0, 2], [playlist, 1, 2], [playlist, 2, 2]])

        // With nothing to download, it says nothing.
        await progress.clear()
        _ = try await engine.sync(clementine)
        #expect(await progress.heard.isEmpty)
    }

    @Test func aRuleKeptAsItIsSyncsOnceUntilItHasItsSongs() async throws {
        let album = try await rule("library/album/Pixies/Doolittle", refreshPolicy: .never)
        // The first sync fails, so the next one asks again.
        guard case .failed = try await engine.sync(clementine).rules[album] else {
            Issue.record("Expected the first sync to fail")
            return
        }

        await clementine.serve("library/album/Pixies/Doolittle", [await song("a")])
        #expect(try await engine.sync(clementine).rules[album] == .synced(songs: 1, downloaded: 1, skipped: 0))

        // Once it has its songs, it isn't asked for them again, and keeps them.
        await clementine.serve("library/album/Pixies/Doolittle", [await song("a"), await song("b", title: "Tame")])
        await clementine.clearRequests()
        let result = try await engine.sync(clementine)
        #expect(result.rules[album] == nil)
        #expect(await clementine.requests.isEmpty)
        #expect(result.removed == 0)
        #expect(try await store.ruleItems(ruleID: album).map(\.itemKey) == ["a"])
    }

    @Test func aSongInTwoRulesIsDownloadedOnceAndKeptWhileEitherWantsIt() async throws {
        let album = try await rule("library/album/Pixies/Doolittle")
        let playlist = try await rule("playlist/1")
        await clementine.serve("library/album/Pixies/Doolittle", [await song("a"), await song("b", title: "Tame")])
        await clementine.serve("playlist/1", [await song("a")])
        _ = try await engine.sync(clementine)
        #expect(await clementine.opened.count == 2)

        // The album's dropped: its other song goes, the playlist's stays.
        try await store.removeRule(id: album)
        let result = try await engine.sync(clementine)
        #expect(result.removed == 1)
        #expect(try await store.item(serverID: Self.server, itemKey: "a") != nil)
        #expect(try await store.item(serverID: Self.server, itemKey: "b") == nil)
        #expect(try files().count == 1)
        #expect(try await store.ruleItems(ruleID: playlist).map(\.itemKey) == ["a"])
    }

    @Test func songsLeavingARuleAreDeleted() async throws {
        _ = try await rule("playlist/1")
        await clementine.serve("playlist/1", [await song("a"), await song("b", title: "Tame")])
        _ = try await engine.sync(clementine)

        await clementine.serve("playlist/1", [await song("b", title: "Tame")])
        #expect(try await engine.sync(clementine).removed == 1)
        #expect(try Set(files().keys) == ["Pixies/Doolittle/01 Tame.flac"])
    }

    @Test func pinnedSongsAreKept() async throws {
        _ = try await rule("playlist/1")
        await clementine.serve("playlist/1", [await song("a")])
        _ = try await engine.sync(clementine)
        try await store.setPinned(serverID: Self.server, itemKey: "a", pinned: true)

        await clementine.serve("playlist/1", [])
        #expect(try await engine.sync(clementine).removed == 0)
        #expect(try files().count == 1)
    }

    @Test func songsWithTheSameNameAreKeptApart() async throws {
        _ = try await rule("playlist/1")
        await clementine.serve("playlist/1", [await song("a", title: "Intro"), await song("b", title: "Intro")])
        _ = try await engine.sync(clementine)

        #expect(try Set(files().keys) == ["Pixies/Doolittle/01 Intro.flac", "Pixies/Doolittle/01 Intro (2).flac"])
    }

    @Test func goneAndUnsetUpSourcesKeepTheirSongs() async throws {
        let gone = try await rule("playlist/1")
        let smart = try await rule("smart/library/0b6e")
        await clementine.serve("playlist/1", [await song("a")])
        await clementine.serve("smart/library/0b6e", [await song("b", title: "Tame")])
        _ = try await engine.sync(clementine)

        await clementine.answer("playlist/1", state: .gone)
        await clementine.answer("smart/library/0b6e", state: .needsSetup, message: "Not yet")
        let result = try await engine.sync(clementine)

        #expect(result.rules[gone] == .gone)
        #expect(result.rules[smart] == .needsSetup("Not yet"))
        #expect(result.removed == 0)
        #expect(try files().count == 2)
    }

    @Test func aFailedRuleKeepsItsSongsAndTheOthersCarryOn() async throws {
        let first = try await rule("playlist/1")
        let second = try await rule("playlist/2")
        await clementine.serve("playlist/1", [await song("a")])
        await clementine.serve("playlist/2", [await song("b", title: "Tame")])
        _ = try await engine.sync(clementine)

        // The first's new song can't be fetched.
        await clementine.serve("playlist/1", [await song("a"), await song("c", title: "Hey")])
        await clementine.remove("/d/token/c-1")
        await clementine.serve("playlist/2", [await song("b", title: "Tame"), await song("d", title: "Gouge Away")])
        let result = try await engine.sync(clementine)

        guard case .failed = result.rules[first] else {
            Issue.record("Expected the first rule to fail, not \(String(describing: result.rules[first]))")
            return
        }
        #expect(result.rules[second] == .synced(songs: 2, downloaded: 1, skipped: 0))
        #expect(try await store.ruleItems(ruleID: first).map(\.itemKey) == ["a"])
        #expect(result.removed == 0)
    }

    @Test func aSyncCutShortKeepsWhatItDownloaded() async throws {
        let album = try await rule("library/album/Pixies/Doolittle")
        await clementine.serve(
            "library/album/Pixies/Doolittle", [await song("a"), await song("b", track: 2), await song("c", track: 3)])
        await clementine.remove("/d/token/c-1")
        let result = try await engine.sync(clementine)

        guard case .failed = result.rules[album] else {
            Issue.record("Expected the rule to fail, not \(String(describing: result.rules[album]))")
            return
        }
        #expect(try await store.ruleItems(ruleID: album).map(\.itemKey) == ["a", "b"])
        #expect(result.removed == 0)
        #expect(try files().count == 2)

        // Next time, only what's left is downloaded.
        _ = await song("c", track: 3)
        await clementine.clearOpened()
        _ = try await engine.sync(clementine)
        #expect(await clementine.opened == ["/d/token/c-1"])
    }

    @Test func namesFilesForPeople() {
        var song = SongMetadata()
        song.title = "What/Ever?"
        song.albumartist = "A: B"
        song.artist = "Someone"
        #expect(SyncFiles.relativeDirectory(song) == "A_ B/Unknown album/")
        #expect(SyncFiles.fileName(song, mimeType: "audio/ogg; codecs=opus") == "What_Ever_.opus")
        #expect(SyncFiles.fileExtension("audio/mpeg") == "mp3")
        #expect(SyncFiles.fileExtension("audio/ogg; codecs=vorbis") == "ogg")
        song.track = 12
        #expect(SyncFiles.fileName(song, mimeType: "audio/flac") == "12 What_Ever_.flac")
    }
}

/// Playing what's kept on this phone.
struct PhonePlayerTests {
    static func item(_ key: String, title: String = "", artist: String = "", albumartist: String = "") throws -> SyncedItem {
        var song = SongMetadata()
        song.title = title
        song.artist = artist
        song.albumartist = albumartist
        song.album = "Doolittle"
        song.prettyLength = "2:52"
        return SyncedItem(
            serverID: "s", itemKey: key, version: "1", path: "Pixies/Doolittle/01 \(key).flac", mimeType: "audio/flac",
            sizeBytes: 1, delivery: .original, artKey: nil, metadata: try song.serializedData(), added: .now)
    }

    @Test func readsAKeptSongsTags() throws {
        let folder = URL(filePath: "/synced", directoryHint: .isDirectory)
        let song = KeptSong(try Self.item("a", title: "Debaser", artist: "Pixies"), in: folder)
        #expect(song.title == "Debaser")
        #expect(song.artist == "Pixies")
        #expect(song.album == "Doolittle")
        #expect(song.length == "2:52")
        #expect(song.file.path == "/synced/Pixies/Doolittle/01 a.flac")

        // Without a title, the file's name; without an artist, the album artist.
        let untitled = KeptSong(try Self.item("b", albumartist: "Pixies"), in: folder)
        #expect(untitled.title == "01 b")
        #expect(untitled.artist == "Pixies")
    }

    @Test func playsADownloadedSongWithWhatsKept() {
        let file = URL(filePath: "/Documents/Clementine/Pixies/Debaser.mp3")
        let song = KeptSong(DownloadedSong(title: "Debaser", artist: "Pixies", album: "Doolittle", file: file))
        #expect(song.itemKey == file.absoluteString)
        #expect(song.title == "Debaser")
        #expect(song.album == "Doolittle")
        #expect(song.length.isEmpty)
        #expect(song.file == file)
    }

    @Test func playsFromASongOrAtRandom() throws {
        let folder = URL(filePath: "/synced", directoryHint: .isDirectory)
        let songs = try ["a", "b", "c"].map { KeptSong(try Self.item($0, title: $0), in: folder) }
        #expect(PhonePlayer.order(songs, from: 1, shuffled: false).map(\.itemKey) == ["b", "c"])
        #expect(PhonePlayer.order(songs, from: 9, shuffled: false).map(\.itemKey) == ["c"])
        #expect(Set(PhonePlayer.order(songs, from: 1, shuffled: true).map(\.itemKey)) == ["a", "b", "c"])
        #expect(PhonePlayer.order([], from: 0, shuffled: true).isEmpty)
    }

    @Test func shufflesWhatsLeftOrPutsItBackInOrder() throws {
        let folder = URL(filePath: "/synced", directoryHint: .isDirectory)
        let chosen = try ["a", "b", "c", "d"].map { KeptSong(try Self.item($0, title: $0), in: folder) }
        let left = [chosen[3], chosen[1]]
        #expect(PhonePlayer.upcoming(left, chosen: chosen, shuffled: false).map(\.itemKey) == ["b", "d"])
        #expect(Set(PhonePlayer.upcoming(left, chosen: chosen, shuffled: true).map(\.itemKey)) == ["b", "d"])
    }
}
