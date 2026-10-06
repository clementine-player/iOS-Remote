import ClementineWatch
import Foundation
import Testing

struct WatchTests {
    @Test func sendsWhatsPlaying() {
        let state = WatchNowPlaying(
            connection: .connected, hostName: "studio-pc", title: "Clair de lune", artist: "Claude Debussy",
            isPlaying: true, volume: 60, length: 300, position: 42, cover: Data([1, 2, 3]))
        let message = WatchLinkCoding.encode(state)
        #expect(WatchLinkCoding.decodeState(message[WatchLinkCoding.stateKey] as? Data) == state)
    }

    @Test func sendsCommands() {
        for command in [WatchCommand.playPause, .previous, .next, .love, .setVolume(35), .refresh] {
            #expect(WatchLinkCoding.decodeCommand(WatchLinkCoding.encode(command)) == command)
        }
    }

    @Test func countsOnWhilePlaying() {
        let start = Date.now
        var state = WatchNowPlaying(isPlaying: true, length: 100, position: 10, positionDate: start)
        #expect(state.position(at: start.addingTimeInterval(5)) == 15)
        #expect(state.position(at: start.addingTimeInterval(500)) == 100)
        state.isPlaying = false
        #expect(state.position(at: start.addingTimeInterval(5)) == 10)
    }

    @Test func positionMovingOnIsNothingNew() {
        let start = Date.now.addingTimeInterval(-10)
        let sent = WatchNowPlaying(title: "Clair de lune", isPlaying: true, length: 300, position: 0, positionDate: start)
        var now = sent
        now.position = 10
        now.positionDate = .now
        #expect(!now.differs(from: sent))
        now.position = 60
        #expect(now.differs(from: sent))
        now.position = 10
        now.volume = 50
        #expect(now.differs(from: sent))
    }
}
