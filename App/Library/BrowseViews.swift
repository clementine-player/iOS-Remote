import ClementineKit
import SwiftUI

/// The rows of a level of the library or search results. Groups open the level below; songs are
/// added to the playlist. In edit mode, rows are selected instead.
struct BrowseRows: View {
    let level: BrowseLevel
    @Binding var selection: Set<Int>
    let isEditing: Bool
    var icons: [String: UIImage] = [:]
    let addSong: (BrowseItem) -> Void

    var body: some View {
        ForEach(Array(level.items.enumerated()), id: \.offset) { index, item in
            Group {
                if isEditing {
                    Button {
                        if selection.contains(index) {
                            selection.remove(index)
                        } else {
                            selection.insert(index)
                        }
                    } label: {
                        BrowseRow(item: item, icon: icons[item.value])
                    }
                } else if item.kind == .song {
                    Button {
                        addSong(item)
                    } label: {
                        BrowseRow(item: item, icon: icons[item.value])
                    }
                    .accessibilityHint("Adds it to the playlist")
                } else {
                    NavigationLink(value: item) {
                        BrowseRow(item: item, icon: icons[item.value])
                    }
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(selection.contains(index) ? Palette.secondaryContainer : Palette.surface)
            .listRowSeparator(.hidden)
            .tag(index)
        }
    }
}

struct BrowseRow: View {
    let item: BrowseItem
    var icon: UIImage?

    var body: some View {
        if item.kind == .song {
            MediaRow(title: item.displayTitle, meta: item.songMeta) {
                SongThumbnail()
            }
        } else {
            MediaRow(title: item.displayTitle, meta: item.itemCount.map { String(localized: "\($0) items") } ?? "") {
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

/// The header of an opened group: its name, how many items, and what to do with all of it.
struct BrowseHeader: View {
    let item: BrowseItem
    let count: Int
    let add: () -> Void
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
                Button("Add to playlist", systemImage: "plus", action: add)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("addAll")
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
    var systemImage: String {
        switch self {
        case .artist: "person.fill"
        case .album, .year: "opticaldisc"
        case .source, .genre, .song: "music.note"
        }
    }
}
