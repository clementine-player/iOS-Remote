import ClementineKit
import QuickLook
import SwiftUI

/// What's kept on this phone, when Clementine syncs songs to it (the screen is then On this
/// phone), songs downloading, those downloaded, and every song on the phone, downloaded now or
/// before.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingKey.wifiOnly) private var wifiOnly = false
    @State private var opened: DownloadsModel.Job?
    @State private var previewed: URL?
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSettingsPresented = false

    private var downloads: DownloadsModel { model.downloads }
    private var syncer: Syncer { model.syncer }

    var body: some View {
        NavigationStack {
            List {
                if !syncer.kept.isEmpty {
                    Section {
                        ForEach(syncer.kept) { kept in
                            KeptRow(
                                kept: kept, running: syncer.status.running, canSync: model.session.syncing.available,
                                syncNow: { syncer.syncNow() }, remove: { syncer.remove(kept.id) })
                        }
                    } header: {
                        Text(String(localized: "Kept on this phone", comment: "Heading of the things you chose to keep on the phone."))
                            .textStyle(.labelLarge)
                            .foregroundStyle(Palette.onSurfaceVariant)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                if !downloads.active.isEmpty {
                    Section {
                        ForEach(downloads.active) { job in
                            JobRow(job: job) {
                                downloads.cancel(job.id)
                                model.toasts.show("Download canceled")
                            }
                        }
                    } header: {
                        SectionTitle("Downloading")
                    }
                }
                if !downloads.finished.isEmpty {
                    Section {
                        ForEach(downloads.finished) { job in
                            Button {
                                opened = job
                            } label: {
                                JobRow(job: job, cancel: nil)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.surface)
                            .swipeActions {
                                Button("Remove from list", systemImage: "xmark", role: .destructive) {
                                    downloads.remove(job.id)
                                }
                            }
                        }
                    } header: {
                        SectionTitle("Finished")
                    }
                }
                if wifiOnly {
                    Section {
                        HStack(spacing: Metrics.space3) {
                            Image(systemName: "wifi")
                                .foregroundStyle(Palette.onSurfaceVariant)
                            Text("Downloads only run on Wi-Fi.")
                                .textStyle(.bodyMedium)
                                .foregroundStyle(Palette.onSurfaceVariant)
                            Spacer()
                            Button("Change") { isSettingsPresented = true }
                                .buttonStyle(.borderless)
                        }
                        .padding(Metrics.space3)
                        .background(Palette.surfaceContainerLow, in: .rect(cornerRadius: Metrics.shapeMedium))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Palette.surface)
                    }
                }
                if let songs = downloads.onPhone, !songs.isEmpty {
                    Section {
                        ForEach(songs, id: \.file) { song in
                            Button {
                                previewed = song.file
                            } label: {
                                MediaRow(title: song.title, meta: song.artist) {
                                    SongThumbnail(systemImage: "play.fill")
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.surface)
                        }
                    } header: {
                        SectionTitle("On this phone")
                    }
                }
            }
            .listStyle(.plain)
            .surfaceBackground()
            .overlay {
                if downloads.isEmpty, syncer.kept.isEmpty {
                    ContentUnavailableView(
                        "No downloads", systemImage: "arrow.down.circle",
                        description: Text("Download songs, albums and playlists from the player, the queue and the library. They're saved in the Files app."))
                }
            }
            .navigationTitle(model.isOnThisPhone ? String(localized: "On this phone") : String(localized: "Downloads"))
            .navigationSubtitle(downloads.freeSpace.map { String(localized: "\(formatBytes($0)) free on this phone") } ?? "")
            .connectionToolbar()
            .task {
                downloads.readOnPhone()
                syncer.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                // Songs may have been deleted, or added, in the Files app meanwhile.
                if phase == .active {
                    downloads.readOnPhone()
                }
            }
            .quickLookPreview($previewed, in: downloads.onPhone?.map(\.file) ?? [])
            .sheet(item: $opened) { job in
                DownloadedSongs(job: job)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isSettingsPresented) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark") { isSettingsPresented = false }
                                    .filledButtonTint()
                            }
                        }
                }
            }
        }
    }
}

/// Something kept on this phone, saying how its last sync went, with a menu to sync now and to
/// stop keeping it, which asks first.
private struct KeptRow: View {
    let kept: KeptRule
    let running: Bool
    let canSync: Bool
    let syncNow: () -> Void
    let remove: () -> Void
    @State private var isConfirmingRemove = false

    var body: some View {
        HStack(spacing: Metrics.space4) {
            IconTile(systemImage: systemImage)
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(kept.rule.title)
                    .textStyle(.bodyLarge)
                    .foregroundStyle(Palette.onSurface)
                    .lineLimit(1)
                Text(details)
                    .textStyle(.bodyMedium)
                    .foregroundStyle(isProblem ? Palette.error : Palette.onSurfaceVariant)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Menu {
                if canSync {
                    Button(
                        String(localized: "Sync now", comment: "Menu item: syncs what's kept on the phone with Clementine now."),
                        systemImage: "arrow.triangle.2.circlepath", action: syncNow)
                }
                Button(
                    String(localized: "Remove from this phone…", comment: "Menu item on something kept on the phone; asks first."),
                    systemImage: "trash", role: .destructive
                ) {
                    isConfirmingRemove = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More options")
            .buttonStyle(.borderless)
        }
        .listRowBackground(Palette.surface)
        .alert(
            String(
                localized: "Remove \(kept.rule.title)? Its songs are deleted from this phone, unless something else you keep has them.",
                comment: "Asks before removing something kept on the phone; the placeholder is its name."),
            isPresented: $isConfirmingRemove
        ) {
            Button(
                String(localized: "Remove", comment: "The button that removes something kept on the phone, after asking."),
                role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var systemImage: String {
        switch kept.rule.kind {
        case .album: "opticaldisc"
        case .artist: "music.mic"
        case .playlist, .smartPlaylist: "music.note.list"
        case .unspecified, .song, .internetNode: "music.note"
        }
    }

    private var isProblem: Bool {
        switch kept.result {
        case nil, .synced: false
        default: true
        }
    }

    /// How it stands: why it didn't sync, or what it keeps.
    private var details: String {
        switch kept.result {
        case .needsSetup(let message):
            return message
        case .gone:
            return String(
                localized: "No longer in Clementine",
                comment: "Something kept on the phone that Clementine doesn't have any more, such as a deleted playlist. Its songs stay on the phone.")
        case .failed:
            return String(
                localized: "Couldn't finish syncing. It tries again when you connect.",
                comment: "Something kept on the phone whose sync was cut short, such as by losing the connection.")
        case nil where kept.songs == 0:
            return running
                ? String(localized: "Preparing…", comment: "Something kept on the phone, while Clementine makes the list of its songs.")
                : String(
                    localized: "Waiting for Clementine",
                    comment: "Something kept on the phone that hasn't synced yet, because Clementine isn't reachable.")
        default:
            return [
                String(
                    localized: "Kept as it is",
                    comment: "How often something kept on the phone is updated from Clementine, short: never, so it keeps the songs it has."),
                String(
                    localized: "\(kept.songs) songs, \(formatBytes(kept.bytes))",
                    comment: "How much of something kept is on the phone: the number of songs, and their size, such as \"180 MB\"."),
            ].joined(separator: " · ")
        }
    }
}

private struct JobRow: View {
    let job: DownloadsModel.Job
    let cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: Metrics.space4) {
            IconTile(systemImage: job.systemImage)
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(job.title)
                    .textStyle(.bodyLarge)
                    .foregroundStyle(Palette.onSurface)
                    .lineLimit(1)
                Text(job.subtitle)
                    .textStyle(.bodyMedium)
                    .foregroundStyle(Palette.onSurfaceVariant)
                    // Once finished it may be an error, which should be read in full.
                    .lineLimit(job.isFinished ? nil : 1)
                if !job.isFinished {
                    ProgressView(value: job.status.progress)
                }
                Text(job.sizes)
                    .textStyle(.labelMedium)
                    .monospacedDigit()
                    .foregroundStyle(Palette.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            if let cancel {
                Button("Cancel download", systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: 44, height: 44)
            }
        }
        .contentShape(.rect)
        .listRowBackground(Palette.surface)
        .accessibilityElement(children: .combine)
    }
}

/// The songs of a finished download: tap one to play it, or share them.
private struct DownloadedSongs: View {
    let job: DownloadsModel.Job
    @State private var previewed: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(job.status.songs, id: \.file) { song in
                Button {
                    previewed = song.file
                } label: {
                    MediaRow(title: song.title, meta: song.artist) {
                        SongThumbnail(systemImage: "play.fill")
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.surfaceContainerLow)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if job.status.songs.isEmpty {
                    ContentUnavailableView("No songs", systemImage: "music.note")
                }
            }
            .navigationTitle("Downloaded songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .filledButtonTint()
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(items: job.status.songs.map(\.file))
                        .disabled(job.status.songs.isEmpty)
                }
            }
            .quickLookPreview($previewed, in: job.status.songs.map(\.file))
        }
        .presentationBackground(Palette.surfaceContainerLow)
    }
}

/// Download the current song, its album, or the playlist.
struct DownloadMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Download") {
            Button("Song", systemImage: "music.note") { model.downloads.downloadCurrent(.currentItem) }
            Button("Album", systemImage: "opticaldisc") { model.downloads.downloadCurrent(.itemAlbum) }
            Button("Playlist", systemImage: "list.bullet") { model.downloads.downloadCurrent(.aplaylist) }
        }
    }
}
