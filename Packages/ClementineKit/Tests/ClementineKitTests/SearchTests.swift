import Foundation
import Testing
@testable import ClementineKit

struct SearchTests {

    private func status(_ id: Int32, _ status: Pb_Remote_GlobalSearchStatus) -> RemoteMessage {
        RemoteMessage(.globalSearchStatus) {
            $0.responseGlobalSearchStatus.id = id
            $0.responseGlobalSearchStatus.status = status
        }
    }

    private func result(_ id: Int32, provider: String, songs: [(String, String, String)]) -> RemoteMessage {
        RemoteMessage(.globalSearchResult) {
            $0.responseGlobalSearch.id = id
            $0.responseGlobalSearch.query = "nocturne"
            $0.responseGlobalSearch.searchProvider = provider
            $0.responseGlobalSearch.searchProviderIcon = Data([1, 2, 3])
            $0.responseGlobalSearch.songMetadata = songs.map { title, artist, album in
                var song = SongMetadata()
                song.title = title
                song.artist = artist
                song.album = album
                song.url = "file:///m/\(title.replacingOccurrences(of: " ", with: "%20")).ogg"
                return song
            }
        }
    }

    @Test func groupsResultsByProviderThenGrouping() async throws {
        let store = SearchStore()
        #expect(try await store.handle(status(4, .globalSearchStarted)) == nil)
        try await store.handle(result(4, provider: "Library", songs: [
            ("Nocturne No. 1", "Frédéric Chopin", "Nocturnes"), ("Nocturne No. 2", "Frédéric Chopin", "Nocturnes"),
        ]))
        try await store.handle(result(4, provider: "Jamendo", songs: [("Nocturne", "Someone", "Night")]))
        // Results of another search are ignored.
        try await store.handle(result(3, provider: "Old", songs: [("Old", "Old", "Old")]))
        #expect(try await store.handle(status(4, .globalSearchFinished)) == 4)

        let providers = try #require(try await store.level(below: nil, grouping: .artistAlbum, sorting: .ascending))
        #expect(providers.kind == .source)
        #expect(providers.items.map(\.value) == ["Jamendo", "Library"])
        #expect(await store.icons["Library"] == Data([1, 2, 3]))

        let artists = try #require(try await store.level(below: providers.items[1], grouping: .artistAlbum, sorting: .ascending))
        #expect(artists.kind == .artist)
        #expect(artists.items.map(\.value) == ["Frédéric Chopin"])

        let songs = try await store.songs(of: [providers.items[1]], grouping: .artistAlbum, sorting: .ascending)
        #expect(songs.map(\.title) == ["Nocturne No. 1", "Nocturne No. 2"])
        #expect(songs.first?.url == "file:///m/Nocturne%20No.%201.ogg")
    }

    @Test func aNewSearchReplacesTheLast() async throws {
        let store = SearchStore()
        try await store.handle(status(1, .globalSearchStarted))
        try await store.handle(result(1, provider: "Library", songs: [("A", "B", "C")]))
        try await store.handle(status(2, .globalSearchStarted))
        try await store.handle(status(2, .globalSearchFinished))
        let providers = try await store.level(below: nil, grouping: .artist, sorting: .ascending)
        #expect(providers?.items.isEmpty == true)
    }
}
