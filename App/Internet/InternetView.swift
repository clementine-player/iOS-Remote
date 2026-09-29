import ClementineKit
import SwiftUI

/// Clementine's internet services, browsed as its Internet sidebar shows them: the services, and
/// what's below them, level by level. Tracks and streams play or go on the playlist.
struct InternetView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [BrowseNode] = []

    var body: some View {
        NavigationStack(path: $path) {
            InternetLevelView(node: nil)
                .navigationDestination(for: BrowseNode.self) { node in
                    InternetLevelView(node: node) { goUp(from: node) }
                }
        }
        .onChange(of: model.internet.generation) {
            // A new connection: the nodes shown are gone with the old one.
            path = []
        }
    }

    /// Leaves [node], and anything opened from it.
    private func goUp(from node: BrowseNode) {
        if let index = path.firstIndex(of: node) {
            path.removeSubrange(index...)
        }
    }
}

/// One level: the services, or what's below an opened node. Clementine keeps the level shown up
/// to date, so it's asked for whenever it's shown.
private struct InternetLevelView: View {
    let node: BrowseNode?
    var goUp: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session

    private var browser: InternetBrowser { model.internet }

    var body: some View {
        let listing = browser.listing(of: node)
        List {
            if let node, node.isAddable {
                // How many isn't known until Clementine first answers.
                let answered = listing.state != .loading || !listing.nodes.isEmpty
                InternetHeader(node: node, count: answered ? listing.totalCount : nil) { add([node], $0) }
            }
            ForEach(listing.nodes, id: \.nodeID) { child in
                row(child)
                    .onAppear {
                        if child.nodeID == listing.nodes.last?.nodeID {
                            browser.loadMore(node)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .surfaceBackground()
        .overlay { placeholder(listing) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if listing.state == .loading, !listing.nodes.isEmpty {
                ProgressBanner(text: "Loading…", fraction: nil)
            }
        }
        .navigationTitle(node?.title ?? String(localized: "Internet"))
        .navigationBarTitleDisplayMode(node == nil ? .large : .inline)
        .refreshable { browser.browse(node) }
        .toolbar {
            if node == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionChip()
                }
                .sharedBackgroundVisibility(.visible)
            }
        }
        .task(id: browser.generation) {
            browser.browse(node)
        }
        .onChange(of: listing.state == .gone) { _, gone in
            if gone {
                goUp()
            }
        }
    }

    /// Opens a node with children; plays or adds a track or stream, as tapping a song in the
    /// library does. Touch and hold for what else can be done with it.
    @ViewBuilder
    private func row(_ child: BrowseNode) -> some View {
        Group {
            if child.canOpen {
                NavigationLink(value: child) {
                    InternetRow(node: child)
                }
            } else if child.isAddable {
                Button {
                    add([child], InternetBrowser.tapAction(isPlaying: session.playState == .playing))
                } label: {
                    InternetRow(node: child)
                }
                .accessibilityHint("Plays it, or adds it to the playlist if Clementine is playing")
            } else {
                InternetRow(node: child)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("internetNode")
        .contextMenu {
            if child.isAddable {
                InternetAddActions { add([child], $0) }
            }
        }
        .listRowBackground(Palette.surface)
        .listRowSeparator(.hidden)
    }

    private func add(_ nodes: [BrowseNode], _ action: BrowseAddAction) {
        browser.add(nodes, action: action)
    }

    @ViewBuilder
    private func placeholder(_ listing: InternetBrowser.Listing) -> some View {
        if listing.nodes.isEmpty {
            switch listing.state {
            case .loading:
                ProgressView("Loading…")
            case .needsSetup(let message):
                ContentUnavailableView {
                    Label("Set up in Clementine", systemImage: "gearshape")
                } description: {
                    Text(message)
                }
            case .ready:
                ContentUnavailableView("Nothing here", systemImage: "globe")
            case .gone:
                EmptyView()
            }
        }
    }
}

/// What can be done with a node that can go on the playlist.
struct InternetAddActions: View {
    let add: (BrowseAddAction) -> Void

    var body: some View {
        Button("Play now", systemImage: "play.fill") { add(.playNow) }
        Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { add(.playNext) }
        Button("Add to playlist", systemImage: "plus") { add(.append) }
        Button("Replace playlist", systemImage: "arrow.triangle.2.circlepath") { add(.replace) }
    }
}

/// A node: its title and subtitle, with its service's icon, or one for its kind.
struct InternetRow: View {
    let node: BrowseNode

    var body: some View {
        MediaRow(title: node.title, meta: node.subtitle) {
            if let icon = node.icon {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .frame(width: 40, height: 40)
                    .background(Palette.secondaryContainer, in: .circle)
            } else {
                IconTile(systemImage: node.systemImage)
            }
        }
    }
}

/// The header of an opened node that can go on the playlist, such as an album: its name, how many
/// items, and playing or adding all of it.
private struct InternetHeader: View {
    let node: BrowseNode
    let count: Int?
    let add: (BrowseAddAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .textStyle(.headlineSmall)
                    .foregroundStyle(Palette.onSurface)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let count {
                    Text("\(count) items")
                        .textStyle(.bodyMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                }
            }
            HStack(spacing: Metrics.space2) {
                Button("Play", systemImage: "play.fill") { add(.playNow) }
                    .buttonStyle(.borderedProminent)
                    .filledButtonTint()
                Button("Add to playlist", systemImage: "plus") { add(.append) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .padding(.vertical, Metrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Palette.surface)
        .listRowSeparator(.hidden)
    }
}

extension BrowseNode {
    /// A service's own icon.
    var icon: UIImage? {
        iconPng.isEmpty ? nil : UIImage(data: iconPng)
    }

    /// For a node without its own icon, one for its kind.
    var systemImage: String {
        switch kind {
        case .service: "globe"
        case .track: "music.note"
        case .stream: "dot.radiowaves.left.and.right"
        case .smartPlaylist: "wand.and.stars"
        case .folder, .unspecified: "folder"
        }
    }
}
