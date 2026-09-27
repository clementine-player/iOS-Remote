import Foundation
import Testing
@testable import ClementineKit

struct DownloadTests {

    /// Serves two songs, as Clementine does: the total size, then for each an offer, and if
    /// accepted, its chunks; then "queue empty".
    private func serve(_ clementine: FakeClementine, songs: [(SongMetadata, Data)]) {
        clementine.respond { message, client in
            guard message.type == .downloadSongs else { return }
            try? await client.send(RemoteMessage(.downloadTotalSize) {
                $0.responseDownloadTotalSize.totalSize = Int32(songs.reduce(0) { $0 + $1.1.count })
                $0.responseDownloadTotalSize.fileCount = Int32(songs.count)
            })
            for (number, (song, data)) in songs.enumerated() {
                try? await client.send(RemoteMessage(.songFileChunk) {
                    $0.responseSongFileChunk.chunkNumber = 0
                    $0.responseSongFileChunk.chunkCount = 0
                    $0.responseSongFileChunk.fileNumber = Int32(number + 1)
                    $0.responseSongFileChunk.fileCount = Int32(songs.count)
                    $0.responseSongFileChunk.size = Int32(data.count)
                    $0.responseSongFileChunk.songMetadata = song
                })
                // The app answers each offer before the chunks come.
                try? await clementine.waitUntil { $0.received.filter { $0.type == .songOfferResponse }.count > number }
                guard clementine.received.last(where: { $0.type == .songOfferResponse })?.responseSongOffer.accepted == true else { continue }
                let chunkSize = 4
                let count = (data.count + chunkSize - 1) / chunkSize
                for chunk in 1...count {
                    try? await client.send(RemoteMessage(.songFileChunk) {
                        $0.responseSongFileChunk.chunkNumber = Int32(chunk)
                        $0.responseSongFileChunk.chunkCount = Int32(count)
                        $0.responseSongFileChunk.fileNumber = Int32(number + 1)
                        $0.responseSongFileChunk.fileCount = Int32(songs.count)
                        $0.responseSongFileChunk.size = Int32(data.count)
                        $0.responseSongFileChunk.data = data[(chunk - 1) * chunkSize..<min(chunk * chunkSize, data.count)]
                    })
                }
            }
            try? await client.send(RemoteMessage(.downloadQueueEmpty))
        }
    }

    private func song(_ title: String, artist: String, album: String) -> SongMetadata {
        var song = SongMetadata()
        song.title = title
        song.artist = artist
        song.album = album
        song.filename = "\(title).ogg"
        return song
    }

    @Test func downloadsSongsIntoArtistAndAlbumFolders() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        let songs = [
            (song("Clair de lune", artist: "Claude Debussy", album: "Suite bergamasque"), Data("0123456789".utf8)),
            (song("Menuet", artist: "Claude Debussy", album: "Suite: bergamasque?"), Data("abcdef".utf8)),
        ]
        serve(clementine, songs: songs)

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let downloader = SongDownloader(
            endpoint: clementine.endpoint, authCode: 0, request: Messages.downloadSongs(.itemAlbum),
            playlistName: nil, options: DownloadOptions(directory: directory))
        let status = await downloader.run { _ in }

        #expect(status.state == .finished(nil))
        #expect(status.progress == 1)
        #expect(status.fileCount == 2)
        #expect(status.totalBytes == 16)
        #expect(status.bytes == 16)
        let first = directory.appending(path: "Claude Debussy/Suite bergamasque/Clair de lune.ogg")
        let second = directory.appending(path: "Claude Debussy/Suite bergamasque/Menuet.ogg")
        #expect(try Data(contentsOf: first) == songs[0].1)
        #expect(try Data(contentsOf: second) == songs[1].1)
        #expect(status.songs.map(\.title) == ["Clair de lune", "Menuet"])
        let connect = try #require(clementine.received.first)
        #expect(connect.requestConnect.downloader)
        #expect(clementine.received[1].requestDownloadSongs.downloadItem == .itemAlbum)
    }

    @Test func skipsSongsItHasUnlessReplacing() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        let songs = [(song("Clair de lune", artist: "Claude Debussy", album: "Suite"), Data("new".utf8))]
        serve(clementine, songs: songs)

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var options = DownloadOptions(directory: directory)
        options.artistFolder = false
        let existing = directory.appending(path: "Clair de lune.ogg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existing)

        let status = await SongDownloader(
            endpoint: clementine.endpoint, authCode: 0, request: Messages.downloadSongs(.currentItem),
            playlistName: nil, options: options
        ).run { _ in }
        #expect(status.state == .finished(nil))
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        #expect(status.songs.map(\.file) == [existing])
        #expect(clementine.received.last { $0.type == .songOfferResponse }?.responseSongOffer.accepted == false)
    }

    @Test func playlistFolder() {
        var options = DownloadOptions(directory: URL(filePath: "/d"))
        options.playlistFolder = true
        var song = song("Aria", artist: "Bach", album: "Goldberg Variations")
        song.albumartist = "J. S. Bach"
        let downloader = SongDownloader(
            endpoint: Endpoint(host: "x"), authCode: 0, request: RemoteMessage(.downloadSongs),
            playlistName: "My/Playlist", options: options)
        #expect(downloader.file(for: song).path == "/d/MyPlaylist/J. S. Bach/Goldberg Variations/Aria.ogg")
    }

    @Test func forbidden() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respond { message, client in
            guard message.type == .downloadSongs else { return }
            try? await client.send(RemoteMessage(.disconnect) { $0.responseDisconnect.reasonDisconnect = .downloadForbidden })
        }
        let status = await SongDownloader(
            endpoint: clementine.endpoint, authCode: 0, request: Messages.downloadSongs(.currentItem),
            playlistName: nil, options: DownloadOptions(directory: FileManager.default.temporaryDirectory)
        ).run { _ in }
        #expect(status.state == .finished(.forbidden))
    }

    @Test func wrongAuthCode() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respond { message, client in
            guard message.type == .connect else { return }
            try? await client.send(RemoteMessage(.disconnect) { $0.responseDisconnect.reasonDisconnect = .wrongAuthCode })
        }
        let status = await SongDownloader(
            endpoint: clementine.endpoint, authCode: 0, request: Messages.downloadSongs(.currentItem),
            playlistName: nil, options: DownloadOptions(directory: FileManager.default.temporaryDirectory)
        ).run { _ in }
        #expect(status.state == .finished(.wrongAuthCode))
    }
}
