import ClementineKit
import SwiftUI

/// The rows of a level of the library or search results. Groups open the level below; songs are
/// added to the playlist. Touching and holding a row offers what else can be done with it. In edit
/// mode, rows are selected instead.
struct BrowseRows: View {
    let level: BrowseLevel
    @Binding var selection: Set<Int>
    let isEditing: Bool
    /// A row's icon, when it has its own, such as a search provider's.
    var icon: (BrowseItem) -> UIImage? = { _ in nil }
    /// A row's second line, when not the usual.
    var meta: (BrowseItem) -> String? = { _ in nil }
    /// What a group opens, when not the level below it in the library.
    var opens: ((BrowseItem) -> SearchPage)?
    /// Splits artists, albums and genres into sections by their first letter, with an index.
    var alphabetical = false
    var descending = false
    /// Adds the songs of the items to a playlist, doing an action.
    let add: ([BrowseItem], PlaylistTarget, AddAction) -> Void

    var body: some View {
        if alphabetical, level.kind.isAlphabetical {
            ForEach(sections, id: \.letter) { section in
                Section {
                    rows(section.rows)
                } header: {
                    Text(section.letter)
                        .textStyle(.labelLarge)
                        .foregroundStyle(Palette.primary)
                }
                .sectionIndexLabel(section.letter)
            }
        } else {
            rows(Array(level.items.enumerated()))
        }
    }

    /// The items by their first letter, in letter order; "#" holds those that don't start with one.
    private var sections: [(letter: String, rows: [(offset: Int, element: BrowseItem)])] {
        let grouped = Dictionary(grouping: level.items.enumerated()) { Self.letter(of: $0.element.value) }
        let letters = grouped.keys.sorted { first, second in
            if first == "#" || second == "#" {
                return (first == "#") != descending
            }
            let order = first.localizedStandardCompare(second) == .orderedAscending
            return descending ? !order : order
        }
        return letters.map { ($0, grouped[$0] ?? []) }
    }

    static func letter(of value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let first = folded.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    private func rows(_ rows: [(offset: Int, element: BrowseItem)]) -> some View {
        ForEach(rows, id: \.offset) { index, item in
            Group {
                if isEditing {
                    Button {
                        if selection.contains(index) {
                            selection.remove(index)
                        } else {
                            selection.insert(index)
                        }
                    } label: {
                        BrowseRow(item: item, icon: icon(item), meta: meta(item))
                    }
                } else if item.kind == .song {
                    Button {
                        add([item], .selected, .playIfStopped)
                    } label: {
                        BrowseRow(item: item, icon: icon(item), meta: meta(item))
                    }
                    .accessibilityHint("Adds it to the playlist")
                } else if let opens {
                    NavigationLink(value: opens(item)) {
                        BrowseRow(item: item, icon: icon(item), meta: meta(item))
                    }
                } else {
                    NavigationLink(value: item) {
                        BrowseRow(item: item, icon: icon(item), meta: meta(item))
                    }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !isEditing {
                    BrowseAddActions(item: item) { add([item], $0, $1) }
                }
            }
            .listRowBackground(selection.contains(index) ? Palette.secondaryContainer : Palette.surface)
            .listRowSeparator(.hidden)
            .tag(index)
        }
    }
}

struct BrowseRow: View {
    let item: BrowseItem
    var icon: UIImage?
    /// The second line, when not the usual.
    var meta: String?

    var body: some View {
        if item.kind == .song, icon == nil {
            MediaRow(title: item.displayTitle, meta: meta ?? item.songMeta) {
                SongThumbnail()
            }
        } else {
            MediaRow(title: item.displayTitle, meta: meta ?? item.itemCount.map { String(localized: "\($0) items") } ?? "") {
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .frame(width: 40, height: 40)
                        .background(Palette.secondaryContainer, in: .circle)
                } else {
                    IconTile(systemImage: item.kind.systemImage)
                }
            }
        }
    }
}

/// What can be done with an item of the library or search results, as Clementine's own library
/// offers.
struct BrowseAddActions: View {
    let item: BrowseItem
    let add: (PlaylistTarget, AddAction) -> Void

    @Environment(RemoteSession.self) private var session

    var body: some View {
        Button("Play now", systemImage: "play.fill") { add(.selected, .playNow) }
        if session.canEnqueueNext {
            Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { add(.selected, .playNext) }
        }
        Button("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward") { add(.selected, .queue) }
        Divider()
        Button("Add to playlist", systemImage: "plus") { add(.selected, .append) }
        Button("Replace playlist", systemImage: "arrow.triangle.2.circlepath") { add(.selected, .replace) }
        Button("Open in new playlist", systemImage: "rectangle.stack.badge.plus") {
            add(.new(item.displayTitle), .append)
        }
    }
}

/// The header of an opened group: its name, how many items, and what to do with all of it.
struct BrowseHeader: View {
    let item: BrowseItem
    let count: Int
    let add: (PlaylistTarget) -> Void
    var download: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .textStyle(.headlineSmall)
                    .foregroundStyle(Palette.onSurface)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text("\(count) items")
                    .textStyle(.bodyMedium)
                    .foregroundStyle(Palette.onSurfaceVariant)
            }
            HStack(spacing: Metrics.space2) {
                AddToPlaylistMenu(style: .prominent, add: add)
                if let download {
                    Button("Download", systemImage: "arrow.down", action: download)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("downloadAll")
                }
            }
            .controlSize(.regular)
        }
        .padding(.vertical, Metrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Palette.surface)
        .listRowSeparator(.hidden)
    }
}

extension BrowseItem {
    /// The item's name, "Unknown" when there's none; years come with their album.
    var displayTitle: String {
        if value.isEmpty {
            return String(localized: "Unknown")
        }
        if kind == .year, !album.isEmpty {
            return "\(value) - \(album)"
        }
        return value
    }

    /// A song's artist and album.
    var songMeta: String {
        let unknown = String(localized: "Unknown")
        return "\(artist.isEmpty ? unknown : artist) / \(album.isEmpty ? unknown : album)"
    }
}

extension ItemKind {
    /// Whether items of this kind are named, and so listed by letter.
    var isAlphabetical: Bool {
        self == .artist || self == .album || self == .genre
    }

    var systemImage: String {
        switch self {
        case .artist: "person.fill"
        case .album, .year: "opticaldisc"
        case .source, .genre, .song: "music.note"
        }
    }
}
