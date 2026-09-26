import Foundation
import Testing
@testable import ClementineKit

struct FramingTests {

    @Test func framesWithABigEndianLength() throws {
        let message = RemoteMessage(.play)
        let data = try Framing.encode(message)
        let body = try message.serializedData()
        #expect(data.prefix(4) == Data([0, 0, 0, UInt8(body.count)]))
        #expect(data.dropFirst(4) == body)
    }

    @Test func decodesWhatItEncodes() throws {
        let message = Messages.changeSong(index: 3, playlistID: 9)
        let data = try Framing.encode(message)
        let length = try Framing.length(ofHeader: data.prefix(4))
        let decoded = try Framing.decode(data.dropFirst(4).prefix(length))
        #expect(decoded == message)
        #expect(decoded.version == 21)
    }

    @Test func refusesNegativeAndHugeLengths() {
        #expect(throws: ProtocolError.invalidLength) {
            try Framing.length(ofHeader: Data([0xff, 0xff, 0xff, 0xff]))
        }
        #expect(throws: ProtocolError.invalidLength) {
            try Framing.length(ofHeader: Data([0x04, 0, 0, 0]))
        }
    }

    @Test func refusesAnOlderClementine() throws {
        var old = RemoteMessage(.info)
        old.version = 20
        #expect(throws: ProtocolError.oldProtocol) {
            try Framing.decode(try old.serializedData())
        }
        var unversioned = RemoteMessage(.info)
        unversioned.clearVersion()
        #expect(throws: ProtocolError.oldProtocol) {
            try Framing.decode(try unversioned.serializedData())
        }
    }

    @Test func refusesGarbage() {
        #expect(throws: ProtocolError.invalidData) {
            try Framing.decode(Data([0xff, 0xff, 0xff]))
        }
    }
}

struct MessagesTests {

    @Test func connect() {
        let message = Messages.connect(authCode: 12345, sendPlaylistSongs: true, downloader: false)
        #expect(message.type == .connect)
        #expect(message.requestConnect.authCode == 12345)
        #expect(message.requestConnect.sendPlaylistSongs)
        #expect(message.requestConnect.hasDownloader)
        #expect(!message.requestConnect.downloader)
    }

    @Test func modes() {
        #expect(Messages.shuffle(.insideAlbum).shuffle.shuffleMode == .shuffleInsideAlbum)
        #expect(Messages.repeat(.track).repeat.repeatMode == .repeatTrack)
    }

    @Test func download() {
        let message = Messages.downloadSongs(.urls, urls: ["a", "b"])
        #expect(message.requestDownloadSongs.downloadItem == .urls)
        #expect(message.requestDownloadSongs.playlistID == -1)
        #expect(message.requestDownloadSongs.urls == ["a", "b"])
    }

    @Test func modesCycle() {
        #expect(ShuffleMode.allCases.map(\.next) == [.all, .insideAlbum, .albums, .off])
        #expect(RepeatMode.allCases.map(\.next) == [.track, .album, .playlist, .off])
    }

    @Test func bestLyricsAreTheLongest() {
        let lyrics = [
            Lyrics(provider: "a", title: "A", content: "short"),
            Lyrics(provider: "b", title: "B", content: "much longer"),
            Lyrics(provider: "c", title: "C", content: "mid length"),
        ]
        #expect(Lyrics.best(of: lyrics)?.provider == "b")
        #expect(Lyrics.best(of: []) == nil)
    }
}
