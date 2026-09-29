import Foundation
import Observation

/// A node of the tree Clementine's Internet sidebar shows: a service, or something below one.
public typealias BrowseNode = Pb_Remote_BrowseNode

/// What adding nodes does to the playlist.
public typealias BrowseAddAction = Pb_Remote_BrowseAddAction

/// How adding nodes went.
public typealias BrowseAddResult = Pb_Remote_BrowseAddResult

/// Clementine's internet services, browsed as its Internet sidebar shows them: the services, and
/// the nodes below them, which can go on the playlist as a drag from the sidebar does.
///
/// Clementine names nodes by ids that last as long as the connection, and sends a node's children
/// again whenever they change, as long as it's the node last asked for.
@MainActor
@Observable
public final class InternetBrowser {
    /// A node's children as far as they've arrived.
    public struct Listing: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// Asked for, or still loading in Clementine: more follows.
            case loading
            case ready
            /// The service has to be set up on the computer first; the message says how.
            case needsSetup(String)
            /// The node no longer exists.
            case gone
        }

        public var state = State.loading
        /// The children that have arrived, from the first.
        public var nodes: [BrowseNode] = []
        /// How many children there are in all.
        public var totalCount = 0

        /// Whether there are children still to ask for.
        public var hasMore: Bool {
            nodes.count < totalCount
        }

        public init(state: State = .loading, nodes: [BrowseNode] = [], totalCount: Int = 0) {
            self.state = state
            self.nodes = nodes
            self.totalCount = totalCount
        }
    }

    /// Which connection the node ids belong to: it changes with every connection, when they're
    /// all forgotten.
    public private(set) var generation = 0

    /// Called with the action and result of each add, for the app to say how it went.
    @ObservationIgnored public var onAdded: (@MainActor (BrowseAddAction, BrowseAddResult) -> Void)?

    /// By node id; the services under "".
    private var listings: [String: Listing] = [:]
    /// Where a page has been asked for, by node id, so it's asked for once.
    @ObservationIgnored private var requestedOffsets: [String: Int] = [:]
    /// Adds sent, in order, for the action of their results.
    @ObservationIgnored private var pendingAdds: [(ids: [String], action: BrowseAddAction)] = []
    /// The node last asked for, which Clementine keeps up to date; nil for the services.
    @ObservationIgnored private var watched: BrowseNode?
    @ObservationIgnored private let send: @MainActor (RemoteMessage) -> Void

    /// Asks Clementine with [send].
    public init(send: @escaping @MainActor (RemoteMessage) -> Void) {
        self.send = send
    }

    /// [node]'s children, or the services for nil.
    public func listing(of node: BrowseNode?) -> Listing {
        listings[node?.nodeID ?? ""] ?? Listing()
    }

    /// Asks for [node]'s children, or the services for nil, from the first. Clementine then sends
    /// them again when they change, until another node is asked for.
    public func browse(_ node: BrowseNode?) {
        let id = node?.nodeID ?? ""
        if listings[id] == nil || listings[id]?.state == .gone {
            listings[id] = Listing()
        }
        requestedOffsets[id] = 0
        watched = node
        send(Messages.browse(node?.nodeID))
    }

    /// Asks for the next page of [node]'s children, if there is one not asked for yet.
    public func loadMore(_ node: BrowseNode?) {
        let id = node?.nodeID ?? ""
        guard let listing = listings[id], listing.hasMore, requestedOffsets[id] != listing.nodes.count else { return }
        requestedOffsets[id] = listing.nodes.count
        send(Messages.browse(node?.nodeID, offset: listing.nodes.count))
    }

    /// Puts [nodes] on the current playlist, doing [action].
    public func add(_ nodes: [BrowseNode], action: BrowseAddAction) {
        let ids = nodes.map(\.nodeID)
        pendingAdds.append((ids, action))
        send(Messages.browseAdd(ids, action: action))
    }

    /// What tapping a track or stream does: plays it if Clementine isn't playing, as tapping a song
    /// in the library does, or else adds it to the playlist.
    public static func tapAction(isPlaying: Bool) -> BrowseAddAction {
        isPlaying ? .append : .playNow
    }

    /// Forgets every node, as their ids don't outlive the connection.
    public func reset() {
        listings = [:]
        requestedOffsets = [:]
        pendingAdds = []
        watched = nil
        generation += 1
    }

    /// Handles a message from Clementine; returns whether it was one for the browser.
    @discardableResult
    public func handle(_ message: RemoteMessage) -> Bool {
        switch message.type {
        case .info:
            // A new connection: the old ids mean nothing to it.
            reset()
            return false
        case .browse:
            apply(message.responseBrowse)
        case .browseAddResult:
            let response = message.responseBrowseAdd
            let index = pendingAdds.firstIndex { $0.ids == response.nodeIds } ?? pendingAdds.indices.first
            guard let index else { return true }
            let action = pendingAdds.remove(at: index).action
            onAdded?(action, response.result)
            if response.result == .gone {
                // What's shown is out of date.
                browse(watched)
            }
        default:
            return false
        }
        return true
    }

    private func apply(_ response: Pb_Remote_ResponseBrowse) {
        let id = response.nodeID
        var listing = listings[id] ?? Listing()
        switch response.state {
        case .gone:
            listings[id] = Listing(state: .gone)
            requestedOffsets[id] = nil
            return
        case .loading:
            listing.state = .loading
        case .needsSetup:
            listing.state = .needsSetup(response.message)
        case .ready, .unspecified:
            listing.state = .ready
        }

        // The page replaces what was there, and the list is cut to the children there are now.
        let offset = Int(response.offset)
        let total = Int(response.totalCount)
        if offset <= listing.nodes.count {
            let end = min(listing.nodes.count, offset + response.nodes.count)
            listing.nodes.replaceSubrange(offset..<end, with: response.nodes)
        }
        listing.nodes = Array(listing.nodes.prefix(total))
        listing.totalCount = total
        if let requested = requestedOffsets[id], requested > listing.nodes.count {
            // Asked for a page that the children have since shrunk from.
            requestedOffsets[id] = 0
        }
        listings[id] = listing
    }
}

extension BrowseNode {
    /// Whether it has children to open.
    public var canOpen: Bool {
        children == Pb_Remote_BrowseChildren.some
    }

    /// Whether it can go on the playlist.
    public var isAddable: Bool {
        playability == .addable
    }
}
