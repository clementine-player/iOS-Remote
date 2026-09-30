import ClementineKit
import MediaPlayer
import SwiftUI

/// The full-screen player: artwork, the song, the seek bar, the controls and Clementine's volume.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingKey.showLastFM) private var showLastFM = true
    @State private var isDetailsPresented = false
    @State private var detailsPage = SongDetailsView.Page.details
    @State private var isOutputSheetPresented = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                topBar
                if landscape {
                    HStack(alignment: .center, spacing: Metrics.space6) {
                        artwork
                        VStack(spacing: Metrics.space3) {
                            songInfo
                            SeekBar()
                            TransportControls()
                            VolumeSlider()
                            actions
                        }
                    }
                    .padding(.horizontal, Metrics.space6)
                    .padding(.bottom, Metrics.space4)
                } else {
                    VStack(spacing: 0) {
                        artwork
                            .frame(maxHeight: max(120, geometry.size.height - 430))
                            .padding(.top, Metrics.space3)
                        songInfo
                            .padding(.top, Metrics.space6)
                        SeekBar()
                            .padding(.top, Metrics.space3)
                        TransportControls()
                            .padding(.top, Metrics.space1)
                        VolumeSlider()
                            .padding(.top, Metrics.space2)
                        Spacer(minLength: Metrics.space2)
                        actions
                    }
                    .padding(.horizontal, Metrics.space6)
                    .padding(.bottom, Metrics.space2)
                }
            }
        }
        .background(Palette.surface)
        .sheet(isPresented: $isDetailsPresented) {
            SongDetailsView(page: $detailsPage)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Palette.surfaceContainerLow)
        }
        // The player covers the tabs, so it shows its own.
        .sheet(isPresented: $isOutputSheetPresented) {
            OutputSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(Palette.surfaceContainerLow)
        }
        .toasts(model.toasts)
    }

    private var topBar: some View {
        HStack {
            Button("Close player", systemImage: "chevron.down") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 48, height: 48)
            Spacer()
            VStack(spacing: 0) {
                Text("Playing from")
                    .textStyle(.labelMedium)
                    .foregroundStyle(Palette.onSurfaceVariant)
                Text(session.activePlaylist?.name ?? "")
                    .textStyle(.labelLarge)
                    .foregroundStyle(Palette.onSurface)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Menu {
                Button("Stop", systemImage: "stop.fill") { session.stop() }
                DownloadMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("More options")
        }
        .foregroundStyle(Palette.onSurface)
        .padding(.horizontal, Metrics.space1)
    }

    private var artwork: some View {
        Button {
            showLyrics()
        } label: {
            Artwork(song: session.song)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cover art")
        .accessibilityHint("Shows the lyrics")
        .accessibilityIdentifier("artwork")
    }

    private var songInfo: some View {
        HStack(alignment: .top, spacing: Metrics.space2) {
            SongInfo(song: session.song)
            if showLastFM, session.song != nil {
                Button {
                    session.love()
                    model.toasts.show("Loved on Last.fm")
                } label: {
                    Image(systemName: session.isLoved ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(session.isLoved ? Palette.primary : Palette.onSurfaceVariant)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .disabled(session.isLoved)
                .accessibilityLabel("Love on Last.fm")
            }
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            ActionButton(title: "Lyrics and details", systemImage: "quote.bubble") {
                detailsPage = .details
                isDetailsPresented = true
            }
            Spacer()
            ActionButton(title: "Queue", systemImage: "list.bullet") {
                model.selectedTab = .queue
                dismiss()
            }
            Spacer()
            if session.hasOtherOutputs {
                OutputButton { isOutputSheetPresented = true }
                Spacer()
            }
            Menu {
                DownloadMenu()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(Palette.onSurfaceVariant)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Download")
            Spacer()
        }
    }

    private func showLyrics() {
        guard session.song != nil else { return }
        detailsPage = .lyrics
        isDetailsPresented = true
    }
}

private struct ActionButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Palette.onSurfaceVariant)
                .frame(width: 48, height: 48)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

/// What's playing: title, artist, album, and genre · year, one line each.
struct SongInfo: View {
    let song: Song?
    var alignment = HorizontalAlignment.leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(song?.title ?? String(localized: "No song playing"))
                .textStyle(.headlineMedium)
                .foregroundStyle(Palette.onSurface)
            if let song {
                if !song.artist.isEmpty {
                    Text(song.artist)
                        .textStyle(.titleMedium)
                        .foregroundStyle(Palette.primary)
                }
                if !song.album.isEmpty {
                    Text(song.album)
                        .textStyle(.bodyMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                }
                let details = [song.genre, song.year].filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .textStyle(.labelMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                        .padding(.top, Metrics.space1)
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("songInfo")
    }
}

/// The song's position; it follows the finger while dragging, and Clementine is told on release.
struct SeekBar: View {
    @Environment(RemoteSession.self) private var session
    @State private var dragging: Double?

    var body: some View {
        let song = session.song
        let length = song?.length ?? 0
        let position = session.playState == .stopped ? 0 : session.position
        let shown = dragging.map { Int($0.rounded()) } ?? position
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { dragging ?? Double(min(position, max(length, 1))) },
                    set: { dragging = $0 }),
                in: 0...Double(max(length, 1))
            ) { editing in
                if !editing, let dragging {
                    session.seek(to: Int(dragging.rounded()))
                    self.dragging = nil
                }
            }
            .disabled(length <= 0)
            .accessibilityLabel("Position")
            .accessibilityValue(formatTime(shown))
            if let song {
                HStack {
                    Text((song.isLocal ? "" : String(localized: "Stream") + " ") + formatTime(shown))
                    Spacer()
                    if length > 0 {
                        Text(formatTime(length))
                    }
                }
                .textStyle(.labelMedium)
                .monospacedDigit()
                .foregroundStyle(Palette.onSurfaceVariant)
                .accessibilityHidden(true)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Shuffle · previous · play/pause · next · repeat, always left to right.
struct TransportControls: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        HStack {
            ModeToggle(
                systemImage: "shuffle",
                isOn: session.shuffleMode != .off,
                label: session.shuffleMode.label
            ) {
                model.toasts.show(session.cycleShuffle().label)
            }
            Spacer()
            TransportButton(title: "Previous", systemImage: "backward.end.fill", action: session.previous)
            Spacer()
            PlayPauseButton(playing: session.playState == .playing, action: session.playPause) {
                session.stopAfterCurrent()
                model.toasts.show("Stop after this song")
            }
            Spacer()
            TransportButton(title: "Next", systemImage: "forward.end.fill", action: session.next)
            Spacer()
            ModeToggle(
                systemImage: session.repeatMode == .track ? "repeat.1" : "repeat",
                isOn: session.repeatMode != .off,
                label: session.repeatMode.label
            ) {
                model.toasts.show(session.cycleRepeat().label)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct TransportButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(Palette.onSurface)
                .frame(width: 56, height: 56)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

/// Clementine's volume, not the phone's. While dragging, Clementine follows the thumb. While
/// Clementine plays on this phone, it's the phone's volume instead.
struct VolumeSlider: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        HStack(spacing: Metrics.space3) {
            Image(systemName: "speaker.fill")
            if session.isPlayingHere {
                PhoneVolumeSlider()
                    .frame(height: 34)
                    .accessibilityLabel("Phone volume")
            } else {
                Slider(
                    value: Binding(
                        get: { Double(session.volume) },
                        set: { value in
                            if Int(value.rounded()) != session.volume {
                                session.setVolume(Int(value.rounded()))
                            }
                        }),
                    in: 0...100)
                .accessibilityLabel("Clementine volume")
                .accessibilityValue("\(session.volume)%")
            }
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(Palette.onSurfaceVariant)
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The phone's volume: iOS lets apps change it only through its own slider.
private struct PhoneVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.tintColor = UIColor(Palette.primary)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
