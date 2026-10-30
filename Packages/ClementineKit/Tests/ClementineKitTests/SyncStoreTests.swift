import Foundation
import Testing
@testable import ClementineKit

/// The phone's record of sync rules, synced songs, covers and plays.
struct SyncStoreTests {
    static let server = "4f1c2d6e-8a0b-4c8e-9b7a-2e3f5d6c7b8a"
    static let otherServer = "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a"

    let store: SyncStore

    init() throws {
        // An in-memory database, so each test starts empty.
        store = try SyncStore(url: nil)
    }

    func rule(_ sourceID: String, serverID: String = server, position: Int = 0) -> SyncRule {
        SyncRule(
            serverID: serverID, sourceID: sourceID, title: sourceID, kind: .album, refreshPolicy: .never,
            position: position)
    }

    func item(
        _ itemKey: String, serverID: String = server, version: String = "1", sizeBytes: Int64 = 1000,
        artKey: String? = nil
    ) -> SyncedItem {
        SyncedItem(
            serverID: serverID, itemKey: itemKey, version: version, path: "\(itemKey).flac",
            mimeType: "audio/flac", sizeBytes: sizeBytes, delivery: .original, artKey: artKey,
            metadata: Data([1, 2, 3]), added: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func opensEmpty() async throws {
        #expect(try await store.rules(serverID: Self.server) == [])
        #expect(try await store.items(serverID: Self.server) == [])
        #expect(try await store.usedBytes() == 0)
    }

    @Test func keepsRulesWithEveryField() async throws {
        let added = SyncRule(
            serverID: Self.server, sourceID: "smart/songs/0b6e", title: "Newest tracks", kind: .smartPlaylist,
            refreshPolicy: .afterListening, refreshIntervalHours: 24, refreshAfterPercent: 80,
            limitItems: 50, limitBytes: 2_000_000_000, quality: .alwaysConvert, lossless: .convert, maxBitrateKbps: 160,
            preferredMIMEType: "audio/ogg; codecs=opus", seed: 42, position: 3,
            lastSynced: Date(timeIntervalSince1970: 1_700_000_000))
        let id = try await store.addRule(added)

        var expected = added
        expected.id = id
        #expect(try await store.rule(id: id) == expected)
        #expect(try await store.rules(serverID: Self.server) == [expected])
    }

    @Test func leavesQualityUnsetForThePhonesSettings() async throws {
        let id = try await store.addRule(rule("playlist/1"))
        let read = try #require(try await store.rule(id: id))
        #expect(read.quality == nil)
        #expect(read.lossless == nil)
        #expect(read.maxBitrateKbps == nil)
        #expect(read.preferredMIMEType == nil)
        #expect(read.lastSynced == nil)
    }

    @Test func listsRulesInOrderForOneClementine() async throws {
        try await store.addRule(rule("playlist/2", position: 1))
        try await store.addRule(rule("playlist/1", position: 0))
        try await store.addRule(rule("playlist/9", serverID: Self.otherServer))

        #expect(try await store.rules(serverID: Self.server).map(\.sourceID) == ["playlist/1", "playlist/2"])
        #expect(try await store.rules(serverID: Self.otherServer).map(\.sourceID) == ["playlist/9"])
    }

    @Test func updatesRules() async throws {
        let id = try await store.addRule(rule("playlist/1"))
        var changed = try #require(try await store.rule(id: id))
        changed.lastSynced = Date(timeIntervalSince1970: 5)
        changed.seed = 7
        try await store.updateRule(changed)

        #expect(try await store.rule(id: id) == changed)
    }

    @Test func keepsItemsAndReplacesVersions() async throws {
        try await store.putItem(item("library/1"))
        #expect(try await store.item(serverID: Self.server, itemKey: "library/1") == item("library/1"))

        try await store.putItem(item("library/1", version: "2", sizeBytes: 2000))
        #expect(try await store.item(serverID: Self.server, itemKey: "library/1")?.version == "2")
        #expect(try await store.items(serverID: Self.server).count == 1)
    }

    @Test func keepsEmptyMetadata() async throws {
        var empty = item("library/1")
        empty.metadata = Data()
        try await store.putItem(empty)
        #expect(try await store.item(serverID: Self.server, itemKey: "library/1")?.metadata == Data())
    }

    @Test func keepsAnotherClementinesItemsApart() async throws {
        try await store.putItem(item("library/1"))
        try await store.putItem(item("library/1", serverID: Self.otherServer, version: "9"))

        #expect(try await store.item(serverID: Self.server, itemKey: "library/1")?.version == "1")
        #expect(try await store.item(serverID: Self.otherServer, itemKey: "library/1")?.version == "9")
    }

    @Test func keepsEachRulesOrder() async throws {
        let ruleID = try await store.addRule(rule("library/album/Pixies/Doolittle"))
        for key in ["library/3", "library/1", "library/2"] {
            try await store.putItem(item(key))
        }
        try await store.setRuleItems(
            ruleID: ruleID, serverID: Self.server, itemKeys: ["library/3", "library/1", "library/2"])

        #expect(try await store.ruleItems(ruleID: ruleID).map(\.itemKey) == ["library/3", "library/1", "library/2"])
    }

    @Test func aSongInTwoRulesIsKeptUntilNeitherWantsIt() async throws {
        let album = try await store.addRule(rule("library/album/Pixies/Doolittle"))
        let playlist = try await store.addRule(rule("playlist/1"))
        try await store.putItem(item("library/1"))
        try await store.putItem(item("library/2"))
        try await store.setRuleItems(ruleID: album, serverID: Self.server, itemKeys: ["library/1", "library/2"])
        try await store.setRuleItems(ruleID: playlist, serverID: Self.server, itemKeys: ["library/1"])
        #expect(try await store.unwantedItems(serverID: Self.server) == [])

        try await store.removeRule(id: album)
        #expect(try await store.unwantedItems(serverID: Self.server).map(\.itemKey) == ["library/2"])

        try await store.removeRule(id: playlist)
        #expect(Set(try await store.unwantedItems(serverID: Self.server).map(\.itemKey)) == ["library/1", "library/2"])
    }

    @Test func pinnedSongsAreKept() async throws {
        let ruleID = try await store.addRule(rule("playlist/1"))
        try await store.putItem(item("library/1"))
        try await store.setRuleItems(ruleID: ruleID, serverID: Self.server, itemKeys: ["library/1"])
        try await store.setPinned(serverID: Self.server, itemKey: "library/1", pinned: true)

        try await store.removeRule(id: ruleID)
        #expect(try await store.unwantedItems(serverID: Self.server) == [])
        #expect(try await store.item(serverID: Self.server, itemKey: "library/1")?.pinned == true)
    }

    @Test func removingAnItemRemovesItFromItsRules() async throws {
        let ruleID = try await store.addRule(rule("playlist/1"))
        try await store.putItem(item("library/1"))
        try await store.putItem(item("library/2"))
        try await store.setRuleItems(ruleID: ruleID, serverID: Self.server, itemKeys: ["library/1", "library/2"])

        try await store.removeItem(serverID: Self.server, itemKey: "library/1")
        #expect(try await store.ruleItems(ruleID: ruleID).map(\.itemKey) == ["library/2"])
    }

    @Test func keepsEachCoverOnce() async throws {
        let cover = SyncedArt(artKey: "abc", path: "Art/abc.jpg", sizeBytes: 50)
        try await store.putArt(cover)
        try await store.putArt(cover)
        try await store.putItem(item("library/1", artKey: "abc"))
        try await store.putItem(item("library/2", artKey: "abc"))

        #expect(try await store.art(key: "abc") == cover)
        #expect(try await store.usedBytes() == 2000 + 50)
        #expect(try await store.unusedArt() == [])

        try await store.removeItem(serverID: Self.server, itemKey: "library/1")
        try await store.removeItem(serverID: Self.server, itemKey: "library/2")
        #expect(try await store.unusedArt().map(\.artKey) == ["abc"])
        try await store.removeArt(key: "abc")
        #expect(try await store.art(key: "abc") == nil)
    }

    @Test func keepsPlaysUntilAccepted() async throws {
        let first = try await store.logPlay(PlayLogEntry(
            serverID: Self.server, itemKey: "library/1", played: Date(timeIntervalSince1970: 100),
            listenedMs: 180_000, outcome: .completed))
        try await store.logPlay(PlayLogEntry(
            serverID: Self.server, itemKey: "library/2", played: Date(timeIntervalSince1970: 200),
            listenedMs: 5_000, outcome: .skipped, rating: 0.8))

        let log = try await store.playLog(serverID: Self.server)
        #expect(log.map(\.itemKey) == ["library/1", "library/2"])
        #expect(log[0].rating == nil)
        #expect(log[1].rating == 0.8)
        #expect(log[1].outcome == .skipped)
        #expect(log[1].played == Date(timeIntervalSince1970: 200))

        try await store.removePlays(ids: [first])
        #expect(try await store.playLog(serverID: Self.server).map(\.itemKey) == ["library/2"])
        #expect(try await store.playLog(serverID: Self.otherServer) == [])
    }

    @Test func keepsWhatsOnThePhoneWhenReopened() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Sync.db")

        let id = try await SyncStore(url: url).addRule(rule("playlist/1"))
        #expect(try await SyncStore(url: url).rule(id: id)?.sourceID == "playlist/1")
    }
}
