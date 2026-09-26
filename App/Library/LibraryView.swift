import ClementineKit
import SwiftUI

/// Clementine's library, copied to the phone, browsed level by level.
struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            LibraryLevelView(opened: nil)
                .navigationDestination(for: BrowseItem.self) { item in
                    LibraryLevelView(opened: item)
                }
        }
        .task(id: model.session.endpoint) {
            await model.library.prepare()
        }
    }
}

/// One level of the library: the top, or what's below an opened item.
private struct LibraryLevelView: View {
    let opened: BrowseItem?

    @Environment(AppModel.self) private var model
    @AppStorage(SettingKey.libraryGrouping) private var grouping = LibraryGrouping.artistAlbum.rawValue
    @AppStorage(SettingKey.librarySorting) private var sorting = LibrarySorting.ascending.rawValue
    @State private var level: BrowseLevel?
    @State private var filter = ""
    @State private var selection = Set<Int>()
    @State private var editMode = EditMode.inactive

    private var library: LibraryModel { model.library }

    var body: some View {
        List(selection: editMode.isEditing ? $selection : nil) {
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
                    alphabetical: true, descending: sorting == LibrarySorting.descending.rawValue
                ) { song in
                    Task { await library.add([song]) }
                }
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .surfaceBackground()
        .environment(\.editMode, $editMode)
        .overlay { placeholder }
        .safeAreaInset(edge: .top, spacing: 0) { progress }
        .navigationTitle(opened == nil ? String(localized: "Library") : "")
        .navigationSubtitle(opened == nil && level != nil ? String(localized: "\(level?.items.count ?? 0) items") : "")
        .navigationBarTitleDisplayMode(opened == nil ? .large : .inline)
        .searchable(text: $filter, prompt: "Search the library")
        .refreshable {
            if opened == nil {
                library.download()
            }
        }
        .toolbar { toolbar }
        .task(id: LoadKey(revision: library.revision, filter: filter, grouping: grouping, sorting: sorting, status: library.status)) {
            level = await library.level(below: opened, filter: filter)
            selection = []
        }
    }

    private struct LoadKey: Equatable {
        let revision: Int
        let filter: String
        let grouping: String
        let sorting: String
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
                    .accessibilityIdentifier("downloadLibrary")
            }
        } else if let level, level.items.isEmpty, !filter.isEmpty {
            ContentUnavailableView.search(text: filter)
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
                        .disabled(level?.items.isEmpty ?? true)
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
