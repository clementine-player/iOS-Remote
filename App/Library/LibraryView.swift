import ClementineKit
import SwiftUI

/// Clementine's library, copied to the phone, browsed level by level. Searching it shows the
/// songs, artists and albums that match, as the Search tab does.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        NavigationStack {
            LibraryLevelView(opened: nil, query: query)
                .searchable(text: $query, prompt: "Search the library")
                .navigationDestination(for: BrowseItem.self) { item in
                    LibraryLevelView(opened: item)
                }
                .navigationDestination(for: SearchPage.self) { page in
                    SearchListView(page: page, results: model.library.search)
                }
        }
        .task(id: model.session.endpoint) {
            await model.library.prepare()
        }
    }
}

/// One level of the library: the top, or what's below an opened item. At the top, while
/// searching, the results instead.
private struct LibraryLevelView: View {
    let opened: BrowseItem?
    var query = ""

    @Environment(AppModel.self) private var model
    @AppStorage(SettingKey.libraryGrouping) private var grouping = LibraryGrouping.artistAlbum.rawValue
    @AppStorage(SettingKey.librarySorting) private var sorting = LibrarySorting.ascending.rawValue
    @State private var level: BrowseLevel?
    @State private var selection = Set<Int>()
    @State private var editMode = EditMode.inactive
    /// What the Keep sheet is open for.
    @State private var keeping: BrowseItem?
    @State private var keepingSmartPlaylist: Pb_Remote_SyncSource?
    @State private var showsSmartPlaylists = false

    private var library: LibraryModel { model.library }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            if isSearching {
                SearchSectionsList(results: library.search)
            } else {
                list
            }
        }
        .overlay { placeholder }
        .safeAreaInset(edge: .top, spacing: 0) { progress }
        .navigationTitle(opened == nil ? String(localized: "Library") : "")
        .navigationSubtitle(opened == nil && !isSearching && level != nil ? String(localized: "\(level?.items.count ?? 0) items") : "")
        .navigationBarTitleDisplayMode(opened == nil ? .large : .inline)
        .refreshable {
            if opened == nil {
                library.download()
            }
        }
        .toolbar { toolbar }
        .task(id: LoadKey(revision: library.revision, grouping: grouping, sorting: sorting, status: library.status)) {
            level = await library.level(below: opened)
            selection = []
        }
        .task(id: SearchKey(revision: library.revision, query: query, status: library.status)) {
            guard opened == nil else { return }
            if isSearching {
                // Waits for a pause in typing.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            await library.search.search(query)
        }
    }

    private var list: some View {
        List(selection: editMode.isEditing ? $selection : nil) {
            if opened == nil, !editMode.isEditing, !model.session.smartPlaylists.isEmpty {
                smartPlaylists
            }
            if let opened, let level, !editMode.isEditing {
                BrowseHeader(item: opened, count: level.items.count) { target in
                    Task { await library.add([opened], to: target) }
                } download: {
                    Task { await model.downloads.download(libraryItems: [opened]) }
                }
            }
            if let level {
                BrowseRows(
                    level: level, selection: $selection, isEditing: editMode.isEditing,
                    alphabetical: true, descending: sorting == LibrarySorting.descending.rawValue,
                    keep: { keeping = $0 }, canKeep: { library.canKeep($0) }
                ) { items, target, action in
                    Task { await library.add(items, to: target, action: action) }
                }
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .surfaceBackground()
        .environment(\.editMode, $editMode)
        .sheet(isPresented: Binding { keeping != nil } set: { if !$0 { keeping = nil } }) {
            if let item = keeping {
                // Albums and artists change rarely: kept as they are, unless asked.
                KeepSheet(title: item.displayTitle, refreshPolicy: .never) { policy in
                    Task { await library.keep(item, refreshPolicy: policy) }
                }
            }
        }
        .sheet(
            isPresented: Binding { keepingSmartPlaylist != nil } set: { if !$0 { keepingSmartPlaylist = nil } }
        ) {
            if let smartPlaylist = keepingSmartPlaylist {
                // Made again each time, so it follows what it picks, such as songs added lately.
                KeepSheet(title: smartPlaylist.title, refreshPolicy: .onConnect) { policy in
                    library.keep(smartPlaylist: smartPlaylist, refreshPolicy: policy)
                }
            }
        }
    }

    /// Clementine's smart playlists, in a folder at the top, as Clementine's own library shows
    /// them. Tapping one plays it, or adds it if Clementine is playing, as tapping a song does; its
    /// menu offers the other ways to put it on the playlist, and keeping it on this phone.
    private var smartPlaylists: some View {
        DisclosureGroup(isExpanded: $showsSmartPlaylists) {
            ForEach(model.session.smartPlaylists, id: \.sourceID) { smartPlaylist in
                Button {
                    model.play(smartPlaylist: smartPlaylist, action: .playIfStopped)
                } label: {
                    MediaRow(title: smartPlaylist.title, meta: "") {
                        IconTile(systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Adds it to the playlist")
                .contextMenu {
                    // Clementine puts a smart playlist on the playlist, or makes it dynamic: it
                    // can't queue one, or open it in a new playlist.
                    Button("Play now", systemImage: "play.fill") {
                        model.play(smartPlaylist: smartPlaylist, action: .playNow)
                    }
                    if model.session.canEnqueueNext {
                        Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            model.play(smartPlaylist: smartPlaylist, action: .playNext)
                        }
                    }
                    Divider()
                    Button("Add to playlist", systemImage: "plus") {
                        model.play(smartPlaylist: smartPlaylist, action: .append)
                    }
                    Button("Replace playlist", systemImage: "arrow.triangle.2.circlepath") {
                        model.play(smartPlaylist: smartPlaylist, action: .replace)
                    }
                    if model.session.syncing.available {
                        Divider()
                        KeepButton { keepingSmartPlaylist = smartPlaylist }
                    }
                }
                .listRowBackground(Palette.surface)
                .listRowSeparator(.hidden)
            }
        } label: {
            MediaRow(
                title: String(
                    localized: "Smart playlists",
                    comment: "A folder at the top of the library holding Clementine's smart playlists, such as Newest tracks, as Clementine's own library shows them."),
                meta: String(localized: "\(model.session.smartPlaylists.count) items")
            ) {
                IconTile(systemImage: "wand.and.stars")
            }
        }
        .listRowBackground(Palette.surface)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("librarySmartPlaylists")
    }

    private struct LoadKey: Equatable {
        let revision: Int
        let grouping: String
        let sorting: String
        let status: LibraryModel.Status
    }

    private struct SearchKey: Equatable {
        let revision: Int
        let query: String
        let status: LibraryModel.Status
    }

    @ViewBuilder
    private var placeholder: some View {
        if opened == nil, library.status == .missing {
            ContentUnavailableView {
                Label("No library yet", systemImage: "opticaldisc")
            } description: {
                Text("Your library isn't on this phone yet. Download it from Clementine to browse it here.")
            } actions: {
                Button("Download library") { library.download() }
                    .buttonStyle(.borderedProminent)
                    .filledButtonTint()
                    .accessibilityIdentifier("downloadLibrary")
            }
        } else if isSearching, library.search.searchedFor != nil, library.search.sections.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch library.status {
        case .downloading(let fraction):
            ProgressBanner(text: "Downloading the library…", fraction: fraction)
        case .optimizing:
            ProgressBanner(text: "Preparing the library…", fraction: nil)
        default:
            EmptyView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", systemImage: "checkmark") { endSelection() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                let items = selectedItems
                Text("\(items.count) selected")
                    .textStyle(.bodyMedium)
                Spacer()
                AddToPlaylistMenu { target in
                    Task { await library.add(items, to: target) }
                    endSelection()
                }
                .disabled(items.isEmpty)
                Button("Download", systemImage: "arrow.down") {
                    Task { await model.downloads.download(libraryItems: items) }
                    endSelection()
                }
                .disabled(items.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionChip()
            }
            .sharedBackgroundVisibility(.visible)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More options", systemImage: "ellipsis") {
                    Button("Select", systemImage: "checkmark.circle") { editMode = .active }
                        .disabled(isSearching || level?.items.isEmpty ?? true)
                    Picker("Grouping", systemImage: "rectangle.3.group", selection: $grouping) {
                        ForEach(LibraryGrouping.allCases, id: \.rawValue) { grouping in
                            Text(grouping.title).tag(grouping.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("Sorting", systemImage: "arrow.up.arrow.down", selection: $sorting) {
                        Text("Ascending").tag(LibrarySorting.ascending.rawValue)
                        Text("Descending").tag(LibrarySorting.descending.rawValue)
                    }
                    .pickerStyle(.menu)
                    Divider()
                    Button("Update library", systemImage: "arrow.clockwise") { library.download() }
                }
            }
        }
    }

    private var selectedItems: [BrowseItem] {
        guard let level else { return [] }
        return selection.sorted().compactMap { level.items.indices.contains($0) ? level.items[$0] : nil }
    }

    private func endSelection() {
        selection = []
        editMode = .inactive
    }
}

/// A progress bar with what's happening, at the top of a list.
struct ProgressBanner: View {
    let text: LocalizedStringResource
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(text)
                .textStyle(.bodyMedium)
                .foregroundStyle(Palette.onSurfaceVariant)
        }
        .padding(.horizontal, Metrics.space4)
        .padding(.vertical, Metrics.space2)
        .background(Palette.surface)
        .accessibilityElement(children: .combine)
    }
}
