import ClementineKit
import QuickLook
import SwiftUI

/// Songs downloading, and those downloaded to the phone.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingKey.wifiOnly) private var wifiOnly = false
    @State private var opened: DownloadsModel.Job?
    @State private var isSettingsPresented = false

    private var downloads: DownloadsModel { model.downloads }

    var body: some View {
        NavigationStack {
            List {
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
                        SectionTitle("On this phone")
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
            }
            .listStyle(.plain)
            .surfaceBackground()
            .overlay {
                if downloads.jobs.isEmpty {
                    ContentUnavailableView(
                        "No downloads", systemImage: "arrow.down.circle",
                        description: Text("Download songs, albums and playlists from the player, the queue and the library. They're saved in the Files app."))
                }
            }
            .navigationTitle("Downloads")
            .navigationSubtitle(downloads.freeSpace.map { String(localized: "\(formatBytes($0)) free on this phone") } ?? "")
            .connectionToolbar()
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
