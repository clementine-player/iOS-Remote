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

    private struct Song {
        var title: String
        var artist = ""
        var album = ""
        var albumartist = ""
        var genre = ""
        var isLocal = true
    }

    private func result(_ id: Int32, provider: String, query: String = "nocturne", songs: [Song]) -> RemoteMessage {
        RemoteMessage(.globalSearchResult) {
            $0.responseGlobalSearch.id = id
            $0.responseGlobalSearch.query = query
            $0.responseGlobalSearch.searchProvider = provider
            $0.responseGlobalSearch.searchProviderIcon = Data([1, 2, 3])
            $0.responseGlobalSearch.songMetadata = songs.map { song in
                var metadata = SongMetadata()
                metadata.title = song.title
                metadata.artist = song.artist
                metadata.album = song.album
                metadata.albumartist = song.albumartist
                metadata.genre = song.genre
                metadata.isLocal = song.isLocal
                let name = [song.artist, song.album, song.title].joined(separator: "/")
                metadata.url = (song.isLocal ? "file:///m/" : "http://radio/")
                    + name.replacingOccurrences(of: " ", with: "%20") + ".ogg"
                return metadata
            }
        }
    }

    /// The sections of a search for [query] finding [songs] in the library.
    private func sections(_ query: String, _ songs: [Song], stations: [Song] = []) async throws -> SearchSections {
        let store = SearchStore()
        try await store.handle(status(1, .globalSearchStarted))
        try await store.handle(result(1, provider: "Library", query: query, songs: songs))
        if !stations.isEmpty {
            try await store.handle(result(1, provider: "SomaFM", query: query, songs: stations))
        }
        return await store.sections()
    }

    private let okComputer = [
        Song(title: "Airbag", artist: "Radiohead", album: "OK Computer"),
        Song(title: "Karma Police", artist: "Radiohead", album: "OK Computer"),
        Song(title: "Creep", artist: "Radiohead", album: "Pablo Honey"),
    ]

    @Test func aSongMatchedByTitleIsASong() async throws {
        let found = try await sections("karma police", [
            okComputer[1], Song(title: "Karma Police (Live)", artist: "Radiohead", album: "I Might Be Wrong"),
        ])
        #expect(found.songs.map(\.value) == ["Karma Police", "Karma Police (Live)"])
        #expect(found.artists.isEmpty && found.albums.isEmpty && found.others.isEmpty)
        #expect(found.top == found.songs.first)
        #expect(found.top?.kind == .song)
        #expect(found.top?.artist == "Radiohead")
    }

    @Test func anArtistMatchedIsAnArtistWithItsAlbums() async throws {
        let found = try await sections("radiohead", okComputer)
        #expect(found.artists.map(\.value) == ["Radiohead"])
        #expect(found.artists.first?.itemCount == 2)
        #expect(found.albums.map(\.value) == ["OK Computer", "Pablo Honey"])
        #expect(found.albums.first?.itemCount == 2)
        // Its songs are in it, not listed.
        #expect(found.songs.isEmpty && found.others.isEmpty)
        #expect(found.top?.kind == .artist)
    }

    @Test func anAlbumMatchedIsAnAlbum() async throws {
        let found = try await sections("ok comp", Array(okComputer[0...1]))
        #expect(found.albums.map(\.value) == ["OK Computer"])
        #expect(found.albums.first?.artist == "Radiohead")
        #expect(found.top?.kind == .album)
        #expect(found.songs.isEmpty && found.artists.isEmpty)
    }

    @Test func wordsCanMatchDifferentFields() async throws {
        let help = Song(title: "Help!", artist: "The Beatles", album: "Help!")
        let found = try await sections("beatles help", [help])
        #expect(found.songs.map(\.value) == ["Help!"])
        #expect(found.albums.map(\.value) == ["Help!"])
        #expect(found.artists.isEmpty)
        // Nothing matched on its own, so nothing is the best.
        #expect(found.top == nil)
    }

    @Test func compilationsAreGroupedByAlbumArtist() async throws {
        let found = try await sections("bowie", [
            Song(title: "Heroes", artist: "David Bowie", album: "Now 80s", albumartist: "Various Artists"),
            Song(title: "Starman", artist: "David Bowie", album: "Ziggy Stardust"),
        ])
        #expect(found.artists.map(\.value) == ["David Bowie"])
        #expect(found.albums.map(\.value) == ["Ziggy Stardust"])
        // On someone else's album, the song is listed.
        #expect(found.songs.map(\.value) == ["Heroes"])
    }

    @Test func accentsAndCaseDontMatter() async throws {
        let found = try await sections("GYMNOPEDIE", [
            Song(title: "Gymnopédie No. 1", artist: "Erik Satie", album: "Gymnopédies"),
        ])
        #expect(found.songs.map(\.value) == ["Gymnopédie No. 1"])
        #expect(found.albums.map(\.value) == ["Gymnopédies"])
    }

    @Test func wordsMatchOnlyAtTheirStart() async throws {
        let found = try await sections("head", okComputer)
        #expect(found.artists.isEmpty && found.songs.isEmpty)
        #expect(found.others.count == 3)
    }

    @Test func otherMatchesAreKept() async throws {
        let found = try await sections("jazz", [Song(title: "So What", artist: "Miles Davis", genre: "Jazz")])
        #expect(found.others.map(\.value) == ["So What"])
        #expect(!found.isEmpty)
        #expect(found.top == nil)
    }

    @Test func streamsAreStations() async throws {
        let found = try await sections(
            "groove", [], stations: [Song(title: "Groove Salad", isLocal: false)])
        #expect(found.stations.map(\.value) == ["Groove Salad"])
        #expect(found.stations.first?.selection.first == "SomaFM")
        #expect(found.top?.value == "Groove Salad")
    }

    @Test func fieldNamesAreNotWords() async throws {
        let found = try await sections("artist:radiohead", okComputer)
        #expect(found.artists.map(\.value) == ["Radiohead"])
    }

    @Test func artistsAndAlbumsOpenToTheirResults() async throws {
        let store = SearchStore()
        #expect(try await store.handle(status(4, .globalSearchStarted)) == nil)
        try await store.handle(result(4, provider: "Library", query: "radiohead", songs: okComputer))
        // Results of another search are ignored.
        try await store.handle(result(3, provider: "Library", songs: [Song(title: "Old", artist: "Radiohead")]))
        #expect(try await store.handle(status(4, .globalSearchFinished)) == 4)
        #expect(await store.icons["Library"] == Data([1, 2, 3]))

        let found = await store.sections()
        let artist = try #require(found.artists.first)
        let albums = try #require(try await store.level(below: artist, sorting: .ascending))
        #expect(albums.kind == .album)
        // The albums it opens to are those of the Albums section.
        #expect(albums.items.map(\.selection) == found.albums.map(\.selection))
        #expect(albums.items.map(\.value) == ["OK Computer", "Pablo Honey"])

        let songs = try #require(try await store.level(below: albums.items[0], sorting: .ascending))
        #expect(songs.kind == .song)
        #expect(Set(songs.items.map(\.value)) == ["Airbag", "Karma Police"])

        let all = try await store.songs(of: [artist], sorting: .ascending)
        #expect(all.count == 3)
        #expect(all.first?.url.hasPrefix("file:///m/Radiohead/") == true)
    }

    @Test func aNewSearchReplacesTheLast() async throws {
        let store = SearchStore()
        try await store.handle(status(1, .globalSearchStarted))
        try await store.handle(result(1, provider: "Library", songs: [Song(title: "Nocturne", artist: "B")]))
        #expect(await store.sections().songs.count == 1)
        try await store.handle(status(2, .globalSearchStarted))
        try await store.handle(status(2, .globalSearchFinished))
        #expect(await store.sections().isEmpty)
    }
}
