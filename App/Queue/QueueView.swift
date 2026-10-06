import ClementineKit
import SwiftUI

/// Clementine's open playlists: pick one with the chips, tap a song to play it.
struct QueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @State private var filter = ""
    @State private var selection = Set<Int32>()
    @State private var editMode = EditMode.inactive
    @State private var isClearConfirmationPresented = false
    @State private var isNamingPlaylist = false
    /// The song last tapped to play: the list stays where it is when it starts playing.
    @State private var tappedIndex: Int32?

    private var shown: Playlist? { model.selectedPlaylist }

    private var allSongs: [Song] {
        shown.flatMap { session.playlistSongs[$0.id] } ?? []
    }

    private var songs: [Song] {
        filter.isEmpty ? allSongs : allSongs.filter { $0.matches(filter) }
    }

    /// The song playing, if it's in the playlist shown.
    private var playingIndex: Int32? {
        guard let shown, shown.id == session.activePlaylistID else { return nil }
        return session.song?.index
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                List(selection: $selection) {
                    Section {
                        ForEach(songs, id: \.index) { song in
                            row(song)
                        }
                        .onDelete { offsets in
                            remove(offsets.map { songs[$0] })
                        }
                    } header: {
                        header
                    }
                }
                .listStyle(.plain)
                .surfaceBackground()
                .overlay {
                    if songs.isEmpty, session.playlistsLoading == nil {
                        if filter.isEmpty {
                            ContentUnavailableView("This playlist is empty", systemImage: "music.note")
                        } else {
                            ContentUnavailableView.search(text: filter)
                        }
                    }
                }
                .onChange(of: playingIndex, initial: true) { _, index in
                    let tapped = tappedIndex
                    tappedIndex = nil
                    if index != tapped {
                        scrollToPlaying(scroller)
                    }
                }
                .onChange(of: shown?.id) { _, _ in
                    selection = []
                    scrollToPlaying(scroller)
                }
                .onChange(of: allSongs.count) { old, _ in
                    if old == 0 {
                        scrollToPlaying(scroller)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let loading = session.playlistsLoading {
                    ProgressView(value: Double(loading.done), total: Double(max(loading.total, 1)))
                        .accessibilityLabel("Loading playlists")
                }
            }
            .navigationTitle(shown?.name ?? String(localized: "Queue"))
            .navigationSubtitle(summary)
            .searchable(text: $filter, placement: .navigationBarDrawer, prompt: "Search this playlist")
            .environment(\.editMode, $editMode)
            .toolbar { toolbar }
            .newPlaylistAlert(isPresented: $isNamingPlaylist) { name in
                Task {
                    if let created = await model.playlist(for: .new(name)) {
                        model.selectedPlaylistID = created.id
                    }
                }
            }
            .confirmationDialog(
                "Clear playlist?", isPresented: $isClearConfirmationPresented, titleVisibility: .visible
            ) {
                Button("Clear playlist", role: .destructive) {
                    if let shown {
                        session.clear(playlistID: shown.id)
                    }
                }
            } message: {
                Text("This removes every song from the playlist in Clementine.")
            }
        }
        .onAppear { session.loadPlaylistSongs() }
        .onChange(of: session.status) { _, status in
            if status == .connected {
                session.loadPlaylistSongs()
            }
        }
        .onChange(of: session.playlists) { _, _ in
            session.loadPlaylistSongs()
        }
    }

    @ViewBuilder
    private var header: some View {
        if !session.playlists.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.space2) {
                    ForEach(session.playlists) { playlist in
                        Chip(title: playlist.name, isSelected: playlist.id == shown?.id) {
                            model.selectedPlaylistID = playlist.id
                        }
                    }
                    Button("New playlist", systemImage: "plus") { isNamingPlaylist = true }
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.onSurfaceVariant)
                        .frame(width: 32, height: 32)
                        .overlay {
                            RoundedRectangle(cornerRadius: Metrics.shapeSmall).strokeBorder(Palette.outline)
                        }
                        .contentShape(.rect)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("newPlaylist")
                }
                .padding(.vertical, Metrics.space2)
            }
            .listRowInsets(EdgeInsets())
            .padding(.horizontal, Metrics.space4)
            .background(Palette.surface)
        }
    }

    private func row(_ song: Song) -> some View {
        Button {
            if editMode.isEditing {
                toggle(song)
            } else {
                play(song)
            }
        } label: {
            MediaRow(
                title: song.title,
                meta: [song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "),
                trailing: song.prettyLength,
                playing: song.index == playingIndex
            ) {
                SongThumbnail()
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(selection.contains(song.index) ? Palette.secondaryContainer : Palette.surface)
        .listRowSeparator(.hidden)
        .id(song.index)
        .accessibilityIdentifier("song-\(song.index)")
        .contextMenu {
            Button("Play", systemImage: "play") {
                play(song)
            }
            Button("Remove from playlist", systemImage: "trash", role: .destructive) {
                remove([song])
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", systemImage: "checkmark") {
                    editMode = .inactive
                    selection = []
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                let selected = songs.filter { selection.contains($0.index) }
                Text("\(selected.count) selected")
                    .textStyle(.bodyMedium)
                Spacer()
                Button("Play", systemImage: "play.fill") {
                    if let first = selected.first {
                        play(first)
                    }
                    endSelection()
                }
                .disabled(selected.isEmpty)
                Button("Download", systemImage: "arrow.down") {
                    model.downloads.download(urls: selected.map(\.url))
                    endSelection()
                }
                .disabled(selected.isEmpty)
                Button("Remove from playlist", systemImage: "trash") {
                    remove(selected)
                    endSelection()
                }
                .disabled(selected.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionChip()
            }
            .sharedBackgroundVisibility(.visible)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More options", systemImage: "ellipsis") {
                    Button("Select songs", systemImage: "checkmark.circle") {
                        editMode = .active
                    }
                    .disabled(songs.isEmpty)
                    Button("New playlist", systemImage: "plus") {
                        isNamingPlaylist = true
                    }
                    Divider()
                    Button("Download playlist", systemImage: "arrow.down.circle") {
                        if let shown {
                            model.downloads.download(playlist: shown)
                        }
                    }
                    Button("Close playlist", systemImage: "xmark.rectangle") {
                        if let shown {
                            session.close(playlistID: shown.id)
                            model.selectedPlaylistID = nil
                        }
                    }
                    Button("Clear playlist", systemImage: "trash", role: .destructive) {
                        isClearConfirmationPresented = true
                    }
                    .disabled(allSongs.isEmpty)
                }
                .disabled(shown == nil)
            }
        }
    }

    private var summary: String {
        guard shown != nil else { return "" }
        let count = allSongs.count
        let minutes = (allSongs.reduce(0) { $0 + max($1.length, 0) } + 30) / 60
        let length = minutes >= 60
            ? String(localized: "\(minutes / 60) h \(minutes % 60) min")
            : String(localized: "\(minutes) min")
        return String(localized: "\(count) songs") + " · " + length
    }

    private func toggle(_ song: Song) {
        if selection.contains(song.index) {
            selection.remove(song.index)
        } else {
            selection.insert(song.index)
        }
    }

    private func endSelection() {
        selection = []
        editMode = .inactive
    }

    private func play(_ song: Song) {
        guard let shown else { return }
        tappedIndex = song.index
        session.play(song, in: shown.id)
    }

    private func remove(_ songs: [Song]) {
        guard let shown else { return }
        session.remove(songs, from: shown.id)
    }

    /// Shows the song playing, a few rows down.
    private func scrollToPlaying(_ scroller: ScrollViewProxy) {
        guard let playingIndex, let row = songs.firstIndex(where: { $0.index == playingIndex }), row > 3 else {
            return
        }
        let target = songs[row - 3].index
        Task { @MainActor in
            scroller.scrollTo(target, anchor: .top)
        }
    }
}
