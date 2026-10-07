import Foundation
import Testing
@testable import ClementineKit

@MainActor
struct InternetBrowserTests {
    let browser: InternetBrowser
    let sent: Sent

    /// What the browser sent Clementine.
    @MainActor
    final class Sent {
        var messages: [RemoteMessage] = []
    }

    init() {
        let sent = Sent()
        self.sent = sent
        browser = InternetBrowser { sent.messages.append($0) }
    }

    static func node(_ id: String, title: String? = nil, children: Bool = false, addable: Bool = true) -> BrowseNode {
        var node = BrowseNode()
        node.nodeID = id
        node.title = title ?? id
        node.kind = children ? .folder : .track
        node.children = children ? .some : .none
        node.playability = addable ? .addable : .none
        return node
    }

    static func response(
        _ id: String = "", state: Pb_Remote_BrowseState = .ready, nodes: [BrowseNode], offset: Int = 0,
        total: Int? = nil, message: String = ""
    ) -> RemoteMessage {
        RemoteMessage(.browse) {
            $0.responseBrowse.nodeID = id
            $0.responseBrowse.state = state
            $0.responseBrowse.nodes = nodes
            $0.responseBrowse.offset = Int32(offset)
            $0.responseBrowse.totalCount = Int32(total ?? nodes.count)
            $0.responseBrowse.message = message
        }
    }

    static func nodes(_ range: Range<Int>) -> [BrowseNode] {
        range.map { node("n\($0)") }
    }

    @Test func asksForTheServices() {
        browser.browse(nil)
        #expect(sent.messages.last?.type == .requestBrowse)
        #expect(sent.messages.last?.requestBrowse.hasNodeID == false)
        #expect(browser.listing(of: nil) == .init(state: .loading))

        #expect(browser.handle(Self.response(nodes: [Self.node("n1", title: "SomaFM", children: true)])))
        let listing = browser.listing(of: nil)
        #expect(listing.state == .ready)
        #expect(listing.nodes.map(\.title) == ["SomaFM"])
        #expect(listing.nodes.first?.canOpen == true)
    }

    @Test func keepsWhatItHasWhileAskingAgain() {
        let service = Self.node("n1", children: true)
        browser.browse(service)
        #expect(sent.messages.last?.requestBrowse.nodeID == "n1")
        browser.handle(Self.response("n1", nodes: Self.nodes(2..<4)))
        browser.browse(service)
        #expect(browser.listing(of: service).nodes.count == 2)
    }

    @Test func showsLoadingThenTheUpdate() {
        let plex = Self.node("n1", children: true)
        browser.browse(plex)
        browser.handle(Self.response("n1", state: .loading, nodes: []))
        #expect(browser.listing(of: plex).state == .loading)
        browser.handle(Self.response("n1", nodes: Self.nodes(2..<5)))
        #expect(browser.listing(of: plex).state == .ready)
        #expect(browser.listing(of: plex).nodes.count == 3)
    }

    @Test func saysWhatToSetUp() {
        let subsonic = Self.node("n1", children: true)
        browser.browse(subsonic)
        browser.handle(Self.response("n1", state: .needsSetup, nodes: [], message: "Set up Subsonic"))
        #expect(browser.listing(of: subsonic).state == .needsSetup("Set up Subsonic"))
    }

    @Test func pagesThroughManyChildren() {
        let genre = Self.node("n1", children: true)
        browser.browse(genre)
        browser.handle(Self.response("n1", nodes: Self.nodes(0..<500), total: 1200))
        #expect(browser.listing(of: genre).hasMore)

        browser.loadMore(genre)
        #expect(sent.messages.last?.requestBrowse.offset == 500)
        // Asked for once, however often the end is reached.
        let count = sent.messages.count
        browser.loadMore(genre)
        #expect(sent.messages.count == count)

        browser.handle(Self.response("n1", nodes: Self.nodes(500..<1000), offset: 500, total: 1200))
        #expect(browser.listing(of: genre).nodes.count == 1000)
        browser.loadMore(genre)
        #expect(sent.messages.last?.requestBrowse.offset == 1000)
        browser.handle(Self.response("n1", nodes: Self.nodes(1000..<1200), offset: 1000, total: 1200))
        #expect(browser.listing(of: genre).nodes.map(\.nodeID) == Self.nodes(0..<1200).map(\.nodeID))
        #expect(!browser.listing(of: genre).hasMore)
    }

    @Test func updatesAPageInPlaceAndCutsToTheTotal() {
        let genre = Self.node("n1", children: true)
        browser.browse(genre)
        browser.handle(Self.response("n1", nodes: Self.nodes(0..<500), total: 700))
        browser.handle(Self.response("n1", nodes: Self.nodes(500..<700), offset: 500, total: 700))
        // The second page changes, and loses some.
        browser.handle(Self.response("n1", nodes: Self.nodes(900..<950), offset: 500, total: 550))
        let ids = browser.listing(of: genre).nodes.map(\.nodeID)
        #expect(ids == (Self.nodes(0..<500) + Self.nodes(900..<950)).map(\.nodeID))
    }

    @Test func goesWhenTheNodeHasGone() {
        let album = Self.node("n7", children: true)
        browser.browse(album)
        browser.handle(Self.response("n7", nodes: Self.nodes(0..<3)))
        browser.handle(Self.response("n7", state: .gone, nodes: []))
        #expect(browser.listing(of: album).state == .gone)
        // Asking again starts afresh.
        browser.browse(album)
        #expect(browser.listing(of: album).state == .loading)
    }

    @Test func forgetsEverythingOnANewConnection() {
        browser.browse(nil)
        browser.handle(Self.response(nodes: Self.nodes(0..<3)))
        let generation = browser.generation
        #expect(!browser.handle(RemoteMessage(.info)))
        #expect(browser.generation == generation + 1)
        #expect(browser.listing(of: nil).nodes.isEmpty)
    }

    @Test func addsAndSaysHowItWent() {
        var results: [(BrowseAddAction, BrowseAddResult)] = []
        browser.onAdded = { results.append(($0, $1)) }
        let station = Self.node("n4")
        browser.add([station], action: .playNext)
        #expect(sent.messages.last?.type == .requestBrowseAdd)
        #expect(sent.messages.last?.requestBrowseAdd.nodeIds == ["n4"])
        #expect(sent.messages.last?.requestBrowseAdd.action == .playNext)
        browser.add([Self.node("n5")], action: .append)

        browser.handle(RemoteMessage(.browseAddResult) {
            $0.responseBrowseAdd.nodeIds = ["n4"]
            $0.responseBrowseAdd.result = .added
        })
        browser.handle(RemoteMessage(.browseAddResult) {
            $0.responseBrowseAdd.nodeIds = ["n5"]
            $0.responseBrowseAdd.result = .gone
        })
        #expect(results.map(\.0) == [.playNext, .append])
        #expect(results.map(\.1) == [.added, .gone])
    }

    @Test func asksAgainWhenAddingSomethingGone() {
        let album = Self.node("n2", children: true)
        browser.browse(album)
        browser.add([Self.node("n9")], action: .append)
        browser.handle(RemoteMessage(.browseAddResult) {
            $0.responseBrowseAdd.nodeIds = ["n9"]
            $0.responseBrowseAdd.result = .gone
        })
        #expect(sent.messages.last?.type == .requestBrowse)
        #expect(sent.messages.last?.requestBrowse.nodeID == "n2")
    }

    @Test func tappingPlaysUnlessPlaying() {
        #expect(InternetBrowser.tapAction(isPlaying: false) == .playNow)
        #expect(InternetBrowser.tapAction(isPlaying: true) == .append)
    }

    @Test func ignoresOtherMessages() {
        #expect(!browser.handle(RemoteMessage(.keepAlive)))
    }

    @Test func sessionKnowsWhetherItCanBrowse() {
        let session = RemoteSession()
        session.apply(RemoteMessage(.info) { $0.responseClementineInfo.features = [.rendering, .browse] })
        #expect(session.canBrowse)
        session.apply(RemoteMessage(.info) { $0.responseClementineInfo.features = [.rendering] })
        #expect(!session.canBrowse)
    }

    @Test func sessionKnowsWhetherItCanQueueSongsToPlayNext() {
        let session = RemoteSession()
        session.apply(RemoteMessage(.info) { $0.responseClementineInfo.features = [.browse, .enqueueNext] })
        #expect(session.canEnqueueNext)
        session.apply(RemoteMessage(.info) { $0.responseClementineInfo.features = [.browse] })
        #expect(!session.canEnqueueNext)
    }
}
