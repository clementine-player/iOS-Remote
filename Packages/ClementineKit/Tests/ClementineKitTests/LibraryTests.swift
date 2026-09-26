import Foundation
import Testing
@testable import ClementineKit

/// A small library in Clementine's format, in a temporary directory.
struct SampleLibrary {
    let directory: URL
    let file: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appending(path: "sample.db")
        let database = try Database(path: file.path)
        try database.execute("""
            CREATE TABLE songs (title TEXT, album TEXT, artist TEXT, albumartist TEXT, track INTEGER,
                disc INTEGER, year INTEGER, genre TEXT, filename BLOB, unavailable INTEGER DEFAULT 0);
            """)
        let songs: [(String, String, String, Int, Int, String, String, Int)] = [
            ("Clair de lune", "Suite bergamasque", "Claude Debussy", 3, 1905, "Classical", "file:///m/Debussy/03%20Clair.ogg", 0),
            ("Prélude", "Suite bergamasque", "Claude Debussy", 1, 1905, "Classical", "file:///m/Debussy/01%20Pr%C3%A9lude.ogg", 0),
            ("Menuet", "Suite bergamasque", "Claude Debussy", 2, 1905, "Classical", "file:///m/Debussy/02+Menuet.ogg", 0),
            ("Gymnopédie No. 1", "Gymnopédies", "Erik Satie", 1, 1888, "Classical", "file:///m/Satie/01.ogg", 0),
            ("Gone", "Gymnopédies", "Erik Satie", 2, 1888, "Classical", "file:///m/Satie/02.ogg", 1),
            ("Untitled", "", "", 1, 0, "", "file:///m/unknown.ogg", 0),
        ]
        for song in songs {
            try database.run(
                "INSERT INTO songs (title, album, artist, albumartist, track, disc, year, genre, filename, unavailable) VALUES (?, ?, ?, '', ?, 1, ?, ?, ?, ?)",
                [.text(song.0), .text(song.1), .text(song.2), .integer(Int64(song.3)), .integer(Int64(song.4)),
                 .text(song.5), .text(song.6), .integer(Int64(song.7))])
        }
    }

    /// The library as it is after downloading: optimised, in its place.
    func store() throws -> LibraryStore {
        try LibraryStore.optimize(file)
        try FileManager.default.moveItem(at: file, to: directory.appending(path: "library.db"))
        return LibraryStore(directory: directory)
    }
}

struct LibraryTests {

    @Test func groupsByArtistThenAlbum() async throws {
        let library = try await SampleLibrary().store()
        let artists = try await library.level(below: nil, grouping: .artistAlbum, sorting: .ascending)
        #expect(artists.kind == .artist)
        #expect(artists.items.map(\.value) == ["", "Claude Debussy", "Erik Satie"])
        #expect(artists.items.map(\.itemCount) == [1, 1, 1])

        let debussy = artists.items[1]
        let albums = try await library.level(below: debussy, grouping: .artistAlbum, sorting: .ascending)
        #expect(albums.kind == .album)
        #expect(albums.items.map(\.value) == ["Suite bergamasque"])
        #expect(albums.items[0].itemCount == 3)

        let songs = try await library.level(below: albums.items[0], grouping: .artistAlbum, sorting: .ascending)
        #expect(songs.kind == .song)
        #expect(songs.items.map(\.value) == ["Prélude", "Menuet", "Clair de lune"])
        #expect(songs.items[0].url == "file:///m/Debussy/01 Prélude.ogg")
        #expect(songs.items[1].url == "file:///m/Debussy/02+Menuet.ogg")
        #expect(songs.items[0].artist == "Claude Debussy")
        #expect(songs.items[0].itemCount == nil)
    }

    @Test func dropsUnavailableSongs() async throws {
        let library = try await SampleLibrary().store()
        let satie = try await library.level(below: nil, grouping: .artist, sorting: .ascending).items[2]
        let songs = try await library.level(below: satie, grouping: .artist, sorting: .ascending)
        #expect(songs.items.map(\.value) == ["Gymnopédie No. 1"])
    }

    @Test func sortsDescending() async throws {
        let library = try await SampleLibrary().store()
        let albums = try await library.level(below: nil, grouping: .album, sorting: .descending)
        #expect(albums.items.map(\.value) == ["Suite bergamasque", "Gymnopédies", ""])
    }

    @Test func groupsByYear() async throws {
        let library = try await SampleLibrary().store()
        let debussy = try await library.level(below: nil, grouping: .artistYear, sorting: .ascending).items[1]
        let years = try await library.level(below: debussy, grouping: .artistYear, sorting: .ascending)
        #expect(years.kind == .year)
        #expect(years.items.first?.value == "1905")
        #expect(years.items.first?.album == "Suite bergamasque")
    }

    @Test func filtersWithTheFullTextIndex() async throws {
        let library = try await SampleLibrary().store()
        let artists = try await library.level(below: nil, filter: "clai", grouping: .artistAlbum, sorting: .ascending)
        #expect(artists.items.map(\.value) == ["Claude Debussy"])
        let quoted = try await library.level(below: nil, filter: "gymno\"", grouping: .artist, sorting: .ascending)
        #expect(quoted.items.map(\.value) == ["Erik Satie"])
    }

    @Test func findsTheSongsOfGroups() async throws {
        let library = try await SampleLibrary().store()
        let artists = try await library.level(below: nil, grouping: .artistAlbum, sorting: .ascending)
        let urls = try await library.songURLs(of: [artists.items[1], artists.items[2]], grouping: .artistAlbum, sorting: .ascending)
        #expect(urls.count == 4)
        #expect(urls.first == "file:///m/Debussy/01 Prélude.ogg")
    }

    @Test func forgetsAnotherClementinesLibrary() async throws {
        let library = try await SampleLibrary().store()
        let settings = Settings(suiteName: UUID().uuidString)
        #expect(await library.prepare(for: "10.0.0.1", settings: settings) == false)
        #expect(await library.exists == false)
    }

    @Test func downloadsTheLibraryFromClementine() async throws {
        let sample = try SampleLibrary()
        let data = try Data(contentsOf: sample.file)
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respond { message, client in
            guard message.type == .getLibrary else { return }
            let chunkSize = 1000
            let count = (data.count + chunkSize - 1) / chunkSize
            for number in 1...count {
                let part = data[(number - 1) * chunkSize..<min(number * chunkSize, data.count)]
                try? await client.send(RemoteMessage(.libraryChunk) {
                    $0.responseLibraryChunk.chunkNumber = Int32(number)
                    $0.responseLibraryChunk.chunkCount = Int32(count)
                    $0.responseLibraryChunk.size = Int32(data.count)
                    $0.responseLibraryChunk.data = Data(part)
                })
            }
        }

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let library = LibraryStore(directory: directory)
        let updates = ProgressLog()
        try await library.download(from: clementine.endpoint, authCode: 0) { updates.append($0) }

        let connect = try #require(clementine.received.first)
        #expect(connect.requestConnect.downloader)
        #expect(updates.values.last == .optimizing)
        #expect(updates.values.contains(.downloading(bytes: Int64(data.count), total: Int64(data.count))))
        let artists = try await library.level(below: nil, grouping: .artist, sorting: .ascending)
        #expect(artists.items.count == 3)
    }

    @Test func forbiddenDownloads() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respond { message, client in
            guard message.type == .getLibrary else { return }
            try? await client.send(RemoteMessage(.disconnect) { $0.responseDisconnect.reasonDisconnect = .downloadForbidden })
        }
        let library = LibraryStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        await #expect(throws: DownloadFailure.forbidden) {
            try await library.download(from: clementine.endpoint, authCode: 0) { _ in }
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [LibraryStore.Progress] = []

    func append(_ value: LibraryStore.Progress) {
        lock.withLock { log.append(value) }
    }

    var values: [LibraryStore.Progress] {
        lock.withLock { log }
    }
}
