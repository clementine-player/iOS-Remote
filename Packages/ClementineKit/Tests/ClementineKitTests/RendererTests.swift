import Foundation
import Testing
@testable import ClementineKit

/// A [Playback] that records what it's asked, and whose state the tests set.
@MainActor
final class FakePlayback: Playback {
    enum Call: Equatable {
        case load(String, startMs: Int64, playing: Bool)
        case queue(String?)
        case play, pause, stop
        case seek(Int64)
        case volume(Float)
    }

    weak var listener: PlaybackListener?
    var state = PlaybackState.idle {
        didSet { listener?.playbackStateChanged() }
    }
    var positionMs: Int64 = 0
    var bufferedPercent = 0
    private(set) var calls: [Call] = []

    func load(_ source: PlaybackSource, startMs: Int64, playing: Bool) {
        calls.append(.load(source.url.absoluteString, startMs: startMs, playing: playing))
    }

    func queue(_ source: PlaybackSource?) { calls.append(.queue(source?.url.absoluteString)) }
    func play() { calls.append(.play) }
    func pause() { calls.append(.pause) }
    func seek(toMs positionMs: Int64) { calls.append(.seek(positionMs)) }
    func setVolume(_ volume: Float) { calls.append(.volume(volume)) }
    func stop() { calls.append(.stop) }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RendererTests {
    let playback = FakePlayback()
    let renderer: Renderer
    let sent: Sent

    /// What the renderer sent Clementine.
    @MainActor
    final class Sent {
        var messages: [RemoteMessage] = []
        var statuses: [Pb_Remote_RendererStatus] {
            messages.filter { $0.type == .rendererStatus }.map(\.rendererStatus)
        }
    }

    init() {
        let sent = Sent()
        self.sent = sent
        renderer = Renderer(playback: playback, server: { Self.server }, statusInterval: .milliseconds(50)) {
            sent.messages.append($0)
        }
    }

    /// Where the renderer connected to Clementine.
    static let server = Endpoint(host: "studio", port: 5501)

    static func item(_ id: Int32, seek: Pb_Remote_SeekMethod = .byteRange, lengthMs: Int64 = 300_000) -> RenderItem {
        var item = RenderItem()
        item.itemID = id
        item.url = "http://studio:5501/s/token/\(id)"
        item.mimeType = "audio/mpeg"
        item.lengthMs = lengthMs
        item.seekMethod = seek
        item.song.title = "Song \(id)"
        return item
    }

    static func load(_ item: RenderItem, at startMs: Int64 = 0, playing: Bool = true) -> RemoteMessage {
        RemoteMessage(.renderLoad) {
            $0.requestRenderLoad.item = item
            $0.requestRenderLoad.startMs = startMs
            $0.requestRenderLoad.startState = playing ? .playing : .paused
        }
    }

    @Test func loadsAndReportsPlaying() async throws {
        #expect(renderer.handle(Self.load(Self.item(1), at: 42_000)))
        #expect(playback.calls == [.load("http://studio:5501/s/token/1", startMs: 42_000, playing: true)])
        #expect(renderer.item?.itemID == 1)
        #expect(sent.statuses.last?.state == .loading)

        playback.positionMs = 42_500
        playback.state = .playing
        let status = try #require(sent.statuses.last)
        #expect(status.itemID == 1)
        #expect(status.state == .playing)
        #expect(status.positionMs == 42_500)

        // While playing, the position goes to Clementine regularly.
        let before = sent.statuses.count
        try await eventually { sent.statuses.count >= before + 2 }
    }

    @Test func stopsReportingWhenPaused() async throws {
        renderer.handle(Self.load(Self.item(1)))
        playback.state = .playing
        renderer.handle(RemoteMessage(.renderPause))
        #expect(playback.calls.last == .pause)
        playback.state = .paused
        #expect(sent.statuses.last?.state == .paused)

        let count = sent.statuses.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent.statuses.count == count)
    }

    @Test func pausedLoadsBufferAsPaused() {
        renderer.handle(Self.load(Self.item(1), playing: false))
        #expect(playback.calls == [.load("http://studio:5501/s/token/1", startMs: 0, playing: false)])
        playback.state = .buffering
        #expect(sent.statuses.last?.state == .paused)
    }

    @Test func seeksInTheURLWithRanges() {
        renderer.handle(Self.load(Self.item(1)))
        renderer.handle(RemoteMessage(.renderSeek) {
            $0.requestRenderSeek.itemID = 1
            $0.requestRenderSeek.positionMs = 90_000
        })
        #expect(playback.calls.last == .seek(90_000))
    }

    @Test func seeksByLoadingANewURL() {
        renderer.handle(Self.load(Self.item(1, seek: .newURL)))
        renderer.handle(RemoteMessage(.renderSeek) {
            $0.requestRenderSeek.itemID = 1
            $0.requestRenderSeek.positionMs = 90_000
            $0.requestRenderSeek.url = "http://studio:5501/s/token/1?start=90000"
        })
        #expect(playback.calls.suffix(2) == [
            .load("http://studio:5501/s/token/1?start=90000", startMs: 0, playing: true),
            .queue(nil),
        ])
        // The new URL starts where the seek went.
        #expect(sent.statuses.last?.positionMs == 90_000)
        playback.positionMs = 1_000
        #expect(renderer.positionMs == 91_000)
    }

    @Test func ignoresASeekForAnotherItem() {
        renderer.handle(Self.load(Self.item(2)))
        renderer.handle(RemoteMessage(.renderSeek) {
            $0.requestRenderSeek.itemID = 1
            $0.requestRenderSeek.positionMs = 90_000
        })
        #expect(playback.calls.count == 1)
    }

    @Test func advancesToThePreloadedItem() {
        renderer.handle(Self.load(Self.item(1)))
        renderer.handle(RemoteMessage(.renderPreload) { $0.requestRenderPreload.item = Self.item(2) })
        #expect(playback.calls.last == .queue("http://studio:5501/s/token/2"))
        playback.state = .playing

        sent.messages = []
        renderer.playbackAdvanced()
        // Clementine hears the first item ended before the status about the second.
        #expect(sent.messages.first?.type == .rendererTrackEnded)
        #expect(sent.messages.first?.rendererTrackEnded.itemID == 1)
        #expect(sent.statuses.last?.itemID == 2)
        #expect(renderer.item?.itemID == 2)
    }

    @Test func endsWithNothingQueued() {
        renderer.handle(Self.load(Self.item(1)))
        playback.state = .playing
        renderer.playbackEnded()
        #expect(sent.messages.contains { $0.type == .rendererTrackEnded && $0.rendererTrackEnded.itemID == 1 })
        #expect(renderer.item == nil)
        playback.state = .idle
        #expect(sent.statuses.last?.state == .idle)
    }

    @Test func stops() {
        renderer.handle(Self.load(Self.item(1)))
        playback.state = .playing
        renderer.handle(RemoteMessage(.renderStop))
        #expect(playback.calls.last == .stop)
        #expect(renderer.item == nil)
        #expect(sent.statuses.last?.state == .idle)
    }

    @Test func setsTheVolume() {
        renderer.handle(RemoteMessage(.renderSetVolume) { $0.requestRenderVolume.volume = 150 })
        #expect(playback.calls == [.volume(1)])
        renderer.handle(RemoteMessage(.renderSetVolume) { $0.requestRenderVolume.volume = 40 })
        #expect(playback.calls.last == .volume(0.4))
    }

    @Test func reportsErrorsWithTheirScope() {
        renderer.handle(Self.load(Self.item(3)))
        renderer.playbackFailed("Network lost", transient: true)
        renderer.playbackFailed("Can't decode", transient: false)
        let errors = sent.messages.filter { $0.type == .rendererError }.map(\.rendererError)
        #expect(errors.map(\.itemID) == [3, 3])
        #expect(errors.map(\.scope) == [.transient, .item])
    }

    @Test func ignoresOtherMessages() {
        #expect(!renderer.handle(RemoteMessage(.play)))
        #expect(!renderer.handle(RemoteMessage(.keepAlive)))
        #expect(playback.calls.isEmpty)
    }

    @Test func resetsWhenTheConnectionGoes() async throws {
        renderer.handle(Self.load(Self.item(1)))
        playback.state = .playing
        renderer.reset()
        #expect(renderer.item == nil)
        #expect(playback.calls.last == .stop)
        let count = sent.statuses.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent.statuses.count == count)
    }

    @Test func describesWhatItPlays() {
        let capabilities = Renderer.capabilities(id: "abc", name: "iPhone")
        #expect(capabilities.rendererID == "abc")
        #expect(capabilities.displayName == "iPhone")
        #expect(capabilities.formats.map(\.mimeType).contains("audio/mpeg"))
        #expect(!capabilities.formats.map(\.mimeType).contains { $0.hasPrefix("audio/ogg") })
        #expect(capabilities.features == [.gapless, .httpRange, .relativeUrls])
    }

    // MARK: Where tracks come from

    @Test func fetchesAPathFromWhereItConnected() {
        var item = Self.item(1, seek: .newURL)
        item.url = "/s/token/1"
        renderer.handle(Self.load(item))
        #expect(playback.calls == [.load("http://studio:5501/s/token/1", startMs: 0, playing: true)])

        renderer.handle(RemoteMessage(.renderSeek) {
            $0.requestRenderSeek.itemID = 1
            $0.requestRenderSeek.positionMs = 90_000
            $0.requestRenderSeek.url = "/s/token/1?t=90000"
        })
        #expect(playback.calls.suffix(2) == [
            .load("http://studio:5501/s/token/1?t=90000", startMs: 0, playing: true),
            .queue(nil),
        ])
    }

    @Test func queuesAPathFromWhereItConnected() {
        renderer.handle(Self.load(Self.item(1)))
        var next = Self.item(2)
        next.url = "/s/token/2"
        renderer.handle(RemoteMessage(.renderPreload) { $0.requestRenderPreload.item = next })
        #expect(playback.calls.last == .queue("http://studio:5501/s/token/2"))
    }

    @Test func resolvesURLsAsClementineMeansThem() {
        let server = Endpoint(host: "203.0.113.7", port: 5500)
        // A full URL is fetched from exactly there.
        #expect(Renderer.resolve("http://radio.example/stream", on: server)?.absoluteString == "http://radio.example/stream")
        #expect(Renderer.resolve("/s/t/1?t=5", on: server)?.absoluteString == "http://203.0.113.7:5500/s/t/1?t=5")
        #expect(Renderer.resolve("/s/t/1", on: Endpoint(host: "clementine.example.org", port: 443))?.absoluteString
            == "http://clementine.example.org:443/s/t/1")
        #expect(Renderer.resolve("/s/t/1", on: Endpoint(host: "2001:db8::1"))?.absoluteString
            == "http://[2001:db8::1]:5500/s/t/1")
        #expect(Renderer.resolve("/s/t/1", on: Endpoint(host: "fe80::1%en0"))?.absoluteString
            == "http://[fe80::1%25en0]:5500/s/t/1")
        // Not connected anywhere: nowhere to fetch a path from.
        #expect(Renderer.resolve("/s/t/1", on: nil) == nil)
    }

    @Test func reportsAPathItCantPlaceAsAnError() {
        let renderer = Renderer(playback: playback, server: { nil }) { sent.messages.append($0) }
        var item = Self.item(1)
        item.url = "/s/token/1"
        renderer.handle(Self.load(item))
        #expect(playback.calls.isEmpty)
        let error = sent.messages.last { $0.type == .rendererError }?.rendererError
        #expect(error?.itemID == 1)
        #expect(error?.scope == .item)
    }

    /// Through NAT or a port forward, Clementine doesn't know the address the phone reached it at, so
    /// it sends a path, which the phone fetches from where it connected.
    @Test func playsAPathFromTheClementineItConnectedTo() async throws {
        let clementine = try await FakeClementine()
        defer { clementine.stop() }
        clementine.respondLikeClementine(extra: OutputTests.streamingClementine(active: OutputTests.phone))

        let session = RemoteSession()
        let renderer = Renderer(playback: playback, server: { session.endpoint }) { session.send($0) }
        session.addObserver { _ = renderer.handle($0) }
        session.connect(to: clementine.endpoint, authCode: 0,
                        renderer: Renderer.capabilities(id: OutputTests.phone, name: "iPhone"))
        try await eventually { session.isPlayingHere }
        let connect = try #require(clementine.received.first)
        #expect(connect.requestConnect.renderer.features.contains(.relativeUrls))

        var item = Self.item(7, seek: .newURL)
        item.url = "/s/token/7?t=1500"
        await clementine.broadcast(Self.load(item, at: 1_500))
        try await eventually { !playback.calls.isEmpty }
        let port = clementine.endpoint.port
        #expect(playback.calls == [.load("http://127.0.0.1:\(port)/s/token/7?t=1500", startMs: 0, playing: true)])
        try await clementine.waitUntil {
            $0.received.contains { $0.type == .rendererStatus && $0.rendererStatus.itemID == 7 }
        }
    }
}
