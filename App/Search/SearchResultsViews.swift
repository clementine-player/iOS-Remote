import ClementineKit
import SwiftUI

/// Search results shown in sections by what matched: Clementine's global search (the Search tab),
/// or the library on the phone (the Library tab's search).
@MainActor
protocol SearchResults: AnyObject, Observable {
    var sections: SearchSections { get }
    /// Each provider's icon, by name.
    var icons: [String: UIImage] { get }
    /// Bumped when the results change, so screens reload them.
    var revision: Int { get }
    /// The level below [opened], an artist or album of the results.
    func level(below opened: BrowseItem) async -> BrowseLevel?
    /// Adds the songs of [items] to [target].
    func add(_ items: [BrowseItem], to target: PlaylistTarget) async
    /// Downloads the songs of [items] to the phone, when they can be.
    var download: (([BrowseItem]) async -> Void)? { get }
}

/// A page of results below the first: all of a section, or what's in an artist or album.
enum SearchPage: Hashable {
    case section(SearchSection)
    case opened(BrowseItem)
}

/// A section of the results.
enum SearchSection: CaseIterable, Hashable {
    case songs, artists, albums, stations, others

    var title: String {
        switch self {
        case .songs: String(localized: "Songs")
        case .artists: String(localized: "Artists")
        case .albums: String(localized: "Albums")
        case .stations: String(localized: "Stations")
        case .others: String(localized: "Other matches")
        }
    }

    var kind: ItemKind {
        switch self {
        case .songs, .stations, .others: .song
        case .artists: .artist
        case .albums: .album
        }
    }

    func items(of sections: SearchSections) -> [BrowseItem] {
        switch self {
        case .songs: sections.songs
        case .artists: sections.artists
        case .albums: sections.albums
        case .stations: sections.stations
        case .others: sections.others
        }
    }

    /// A row's second line in this section, when not the usual: an album's artist, a station's
    /// provider.
    func meta(of item: BrowseItem) -> String? {
        switch self {
        case .songs, .others: nil
        case .artists: item.itemCount.map { String(localized: "\($0) albums") }
        case .albums: item.artist.isEmpty ? String(localized: "Unknown") : item.artist
        case .stations: item.selection.first
        }
    }

    /// The top result's second line: what it is, and whose.
    func topMeta(of item: BrowseItem) -> String {
        let artist = item.artist.isEmpty ? String(localized: "Unknown") : item.artist
        return switch self {
        case .songs, .others: String(localized: "Song · \(artist)")
        case .artists: String(localized: "Artist")
        case .albums: String(localized: "Album · \(artist)")
        case .stations: String(localized: "Station · \(item.selection.first ?? "")")
        }
    }
}

/// The results' first page: the best match, then the first few of each section. Its navigation
/// stack shows [SearchPage]s with [SearchListView].
struct SearchSectionsList: View {
    let results: any SearchResults

    /// How many of each section are shown before See All.
    private static let shown = 4

    var body: some View {
        let sections = results.sections
        let top = sections.top
        List {
            if let top, let section = SearchSection.allCases.first(where: { $0.items(of: sections).first == top }) {
                Section {
                    SearchRow(item: top, section: section, results: results, meta: section.topMeta(of: top))
                } header: {
                    SearchSectionHeader(title: String(localized: "Top Result"))
                }
            }
            ForEach(SearchSection.allCases, id: \.self) { section in
                let all = section.items(of: sections)
                // The top result is shown once, above.
                let items = all.first == top ? Array(all.dropFirst()) : all
                if !items.isEmpty {
                    Section {
                        ForEach(items.prefix(Self.shown), id: \.self) { item in
                            SearchRow(item: item, section: section, results: results)
                        }
                    } header: {
                        SearchSectionHeader(title: section.title, seeAll: items.count > Self.shown ? section : nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .surfaceBackground()
    }
}

private struct SearchSectionHeader: View {
    let title: String
    var seeAll: SearchSection?

    var body: some View {
        HStack {
            Text(title)
                .textStyle(.titleMedium)
                .foregroundStyle(Palette.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let seeAll {
                NavigationLink(value: SearchPage.section(seeAll)) {
                    Text("See All")
                        .textStyle(.labelLarge)
                        .foregroundStyle(Palette.primary)
                }
                .accessibilityLabel(String(localized: "See all \(seeAll.title)"))
            }
        }
    }
}

/// A result on the first page: a song or station adds itself to the playlist; an artist or album
/// opens.
private struct SearchRow: View {
    let item: BrowseItem
    let section: SearchSection
    let results: any SearchResults
    var meta: String?

    var body: some View {
        let row = BrowseRow(item: item, icon: icon, meta: meta ?? section.meta(of: item))
        Group {
            if item.kind == .song {
                Button {
                    Task { await results.add([item], to: .selected) }
                } label: {
                    row
                }
                .accessibilityHint("Adds it to the playlist")
            } else {
                NavigationLink(value: SearchPage.opened(item)) {
                    row
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Palette.surface)
        .listRowSeparator(.hidden)
    }

    private var icon: UIImage? {
        section == .stations ? results.icons[item.selection.first ?? ""] : nil
    }
}

/// A page of results: all of a section, or what's in an artist or album.
struct SearchListView: View {
    let page: SearchPage
    let results: any SearchResults

    @AppStorage(SettingKey.librarySorting) private var sorting = LibrarySorting.ascending.rawValue
    @State private var opened: BrowseLevel?
    @State private var selection = Set<Int>()
    @State private var editMode = EditMode.inactive

    private var level: BrowseLevel? {
        switch page {
        case .section(let section):
            BrowseLevel(opened: nil, kind: section.kind, items: section.items(of: results.sections))
        case .opened:
            opened
        }
    }

    var body: some View {
        List(selection: editMode.isEditing ? $selection : nil) {
            if case .opened(let item) = page, let level, !editMode.isEditing {
                BrowseHeader(
                    item: item, count: level.items.count,
                    add: { target in Task { await results.add([item], to: target) } },
                    download: results.download.map { download in { Task { await download([item]) } } })
            }
            if let level {
                BrowseRows(
                    level: level, selection: $selection, isEditing: editMode.isEditing,
                    icon: { item in
                        page == .section(.stations) ? results.icons[item.selection.first ?? ""] : nil
                    },
                    meta: { item in
                        if case .section(let section) = page {
                            return section.meta(of: item)
                        }
                        return nil
                    },
                    opens: { .opened($0) }
                ) { song in
                    Task { await results.add([song], to: .selected) }
                }
            }
        }
        .listStyle(.plain)
        .surfaceBackground()
        .environment(\.editMode, $editMode)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: [String(results.revision), sorting]) {
            if case .opened(let item) = page {
                opened = await results.level(below: item)
            }
            selection = []
        }
    }

    private var title: String {
        switch page {
        case .section(let section): section.title
        case .opened: ""
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", systemImage: "checkmark") { endSelection() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                let items = selection.sorted().compactMap { index in
                    level?.items.indices.contains(index) == true ? level?.items[index] : nil
                }
                Text("\(items.count) selected")
                    .textStyle(.bodyMedium)
                Spacer()
                AddToPlaylistMenu { target in
                    Task { await results.add(items, to: target) }
                    endSelection()
                }
                .disabled(items.isEmpty)
                if let download = results.download {
                    Button("Download", systemImage: "arrow.down") {
                        Task { await download(items) }
                        endSelection()
                    }
                    .disabled(items.isEmpty)
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionChip()
            }
            .sharedBackgroundVisibility(.visible)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select", systemImage: "checkmark.circle") { editMode = .active }
                    .disabled(level?.items.isEmpty ?? true)
            }
        }
    }

    private func endSelection() {
        selection = []
        editMode = .inactive
    }
}
