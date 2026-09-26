import ClementineKit
import SwiftUI

/// Searches everything Clementine can: its library and its internet services.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        NavigationStack {
            SearchLevelView(opened: nil)
                .navigationDestination(for: BrowseItem.self) { item in
                    SearchLevelView(opened: item)
                }
        }
        .searchable(text: $query, prompt: "Search Clementine")
        .onSubmit(of: .search) {
            model.search.search(query)
        }
    }
}

private struct SearchLevelView: View {
    let opened: BrowseItem?

    @Environment(AppModel.self) private var model
    @AppStorage(SettingKey.libraryGrouping) private var grouping = LibraryGrouping.artistAlbum.rawValue
    @AppStorage(SettingKey.librarySorting) private var sorting = LibrarySorting.ascending.rawValue
    @State private var level: BrowseLevel?
    @State private var selection = Set<Int>()
    @State private var editMode = EditMode.inactive

    private var search: SearchModel { model.search }

    var body: some View {
        List(selection: editMode.isEditing ? $selection : nil) {
            if let opened, let level, !editMode.isEditing {
                BrowseHeader(item: opened, count: level.items.count) {
                    Task { await search.add([opened]) }
                }
            }
            if let level {
                BrowseRows(level: level, selection: $selection, isEditing: editMode.isEditing, icons: search.icons) { song in
                    Task { await search.add([song]) }
                }
            }
        }
        .listStyle(.plain)
        .surfaceBackground()
        .environment(\.editMode, $editMode)
        .overlay { placeholder }
        .safeAreaInset(edge: .top, spacing: 0) {
            if opened == nil, search.isSearching, let searchedFor = search.searchedFor {
                ProgressBanner(text: "Searching for “\(searchedFor)”…", fraction: nil)
            }
        }
        .navigationTitle(opened == nil ? String(localized: "Search") : "")
        .navigationBarTitleDisplayMode(opened == nil ? .large : .inline)
        .toolbar { toolbar }
        .task(id: [String(search.revision), grouping, sorting]) {
            level = await search.level(below: opened)
            selection = []
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if opened == nil, !search.isSearching {
            if search.searchedFor == nil {
                ContentUnavailableView(
                    "Search Clementine", systemImage: "magnifyingglass",
                    description: Text("Find music in your library and in Clementine's internet services."))
            } else if level?.items.isEmpty ?? true {
                ContentUnavailableView.search(text: search.searchedFor ?? "")
            }
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
                Button("Add to playlist", systemImage: "plus") {
                    Task { await search.add(items) }
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
