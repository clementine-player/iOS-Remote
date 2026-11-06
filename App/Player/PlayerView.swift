import ClementineKit
import MediaPlayer
import SwiftUI

/// The full-screen player: artwork, the song, the seek bar, the controls and Clementine's volume.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage(SettingKey.showLastFM) private var showLastFM = true
    @State private var isDetailsPresented = false
    @State private var detailsPage = SongDetailsView.Page.details
    @State private var isOutputSheetPresented = false

    /// Clementine, or the songs kept on this phone while they play.
    private var playback: any PlayerSource { model.playback }

    var body: some View {
        GeometryReader { geometry in
            switch geometry.fold(layoutDirection: layoutDirection) {
            case .vertical(let leading, let width):
                // Half-open like a book: the artwork on one side of the fold, the rest on the
                // other. The top row goes over the rest, so nothing sits on the fold.
                HStack(spacing: 0) {
                    artwork
                        .padding(Metrics.space6)
                        .frame(width: leading)
                        .frame(maxHeight: .infinity)
                    Spacer()
                        .frame(width: width)
                    VStack(spacing: 0) {
                        topBar
                        controls
                            .padding(.horizontal, Metrics.space6)
                            .frame(maxHeight: .infinity)
                    }
                    .padding(.bottom, Metrics.space4)
                }
            case .horizontal(let above, let height):
                // Set down like a laptop: the top row at the top as ever, the artwork between it
                // and the fold, and the rest below the fold, scrolling if it doesn't fit.
                VStack(spacing: 0) {
                    topBar
                    artwork
                        .padding(.horizontal, Metrics.space6)
                        .padding(.vertical, Metrics.space3)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(above - Self.topBarHeight, 0))
                    Spacer()
                        .frame(height: height)
                    ScrollView {
                        controls
                            .padding(.horizontal, Metrics.space6)
                            .padding(.bottom, Metrics.space4)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            case nil:
                let landscape = geometry.size.width > geometry.size.height
                VStack(spacing: 0) {
                    topBar
                    if landscape {
                        // The artwork as large as the height allows, leaving the rest a column at
                        // least as wide as a phone's: on wide screens that's the height, on
                        // squarer ones (iPad, an unfolded foldable) more than half the width.
                        let side = min(
                            geometry.size.height - Self.topBarHeight - Metrics.space4,
                            geometry.size.width - 3 * Metrics.space6 - Self.minControlsWidth)
                        HStack(alignment: .center, spacing: Metrics.space6) {
                            artwork
                                .frame(width: max(side, 0), height: max(side, 0))
                            controls
                        }
                        .padding(.horizontal, Metrics.space6)
                        .padding(.bottom, Metrics.space4)
                        .frame(maxHeight: .infinity)
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
            if playback.isOnPhone {
                Label(playingOnThisDevice, systemImage: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
                    .textStyle(.labelLarge)
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1)
                    .accessibilityIdentifier("playingOnPhone")
            } else {
                VStack(spacing: 0) {
                    Text("Playing from", comment: "Small heading at the top of the player, above the name of the playlist the song is playing from.")
                        .textStyle(.labelMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                    Text(session.activePlaylist?.name ?? "")
                        .textStyle(.labelLarge)
                        .foregroundStyle(Palette.onSurface)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Menu {
                Button("Stop", systemImage: "stop.fill") { playback.stop() }
                if !playback.isOnPhone {
                    DownloadMenu()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("More options")
        }
        .foregroundStyle(Palette.onSurface)
        .padding(.horizontal, Metrics.space1)
        .frame(height: Self.topBarHeight)
    }

    /// Where the player says it plays the songs kept on the device.
    private var playingOnThisDevice: String {
        UIDevice.current.userInterfaceIdiom == .pad
            ? String(localized: "Playing on this iPad", comment: "As \"Playing on this phone\", on an iPad.")
            : String(localized: "Playing on this phone", comment: "At the top of the player while it plays the music saved on the phone, where it otherwise says which playlist Clementine plays from.")
    }

    private var artwork: some View {
        Button {
            showLyrics()
        } label: {
            Artwork(song: playback.song)
        }
        .buttonStyle(.plain)
        .disabled(playback.isOnPhone)
        .accessibilityLabel("Cover art")
        .accessibilityHint("Shows the lyrics")
        .accessibilityIdentifier("artwork")
    }

    private static let topBarHeight: CGFloat = 48
    /// The narrowest the song and controls go beside the artwork.
    private static let minControlsWidth: CGFloat = 360

    /// Everything beside or below the artwork when there's room for it in one column.
    private var controls: some View {
        VStack(spacing: Metrics.space3) {
            songInfo
            SeekBar()
            TransportControls()
            VolumeSlider()
            actions
        }
    }

    private var songInfo: some View {
        HStack(alignment: .top, spacing: Metrics.space2) {
            SongInfo(song: playback.song)
            if showLastFM, !playback.isOnPhone, session.song != nil {
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

    /// Playing the songs kept on this phone, only the queue button: it opens them.
    private var actions: some View {
        HStack {
            Spacer()
            if !playback.isOnPhone {
                ActionButton(title: "Lyrics and details", systemImage: "quote.bubble") {
                    detailsPage = .details
                    isDetailsPresented = true
                }
                Spacer()
            }
            ActionButton(title: "Queue", systemImage: "list.bullet") {
                if playback.isOnPhone {
                    model.selectedTab = .downloads
                } else {
                    if let playing = session.activePlaylistID {
                        model.selectedPlaylistID = playing
                    }
                    model.selectedTab = .queue
                }
                dismiss()
            }
            Spacer()
            if !playback.isOnPhone {
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
    }

    private func showLyrics() {
        guard session.song != nil, !playback.isOnPhone else { return }
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
/// While playing it moves on every frame, rather than once a second when Clementine reports it.
struct SeekBar: View {
    @Environment(AppModel.self) private var model
    @State private var dragging: Double?
    @State private var position = SongPosition()

    var body: some View {
        let playback = model.playback
        TimelineView(.animation(paused: playback.playState != .playing)) { _ in
            let song = playback.song
            let length = song?.length ?? 0
            let seconds = position.seconds(for: playback)
            // The time shown ticks over with each whole second, as a clock does.
            let shown = dragging.map { Int($0.rounded()) } ?? Int(seconds)
            VStack(spacing: 0) {
                Slider(
                    value: Binding(
                        get: { dragging ?? min(seconds, Double(max(length, 1))) },
                        set: { dragging = $0 }),
                    in: 0...Double(max(length, 1))
                ) { editing in
                    if !editing, let dragging {
                        position.seek(to: Int(dragging.rounded()))
                        playback.seek(to: Int(dragging.rounded()))
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
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Where the song is, from what Clementine (or the phone's player) last said and this phone's
/// clock since ([PositionClock]).
@MainActor
final class SongPosition {
    private var clock = PositionClock()
    private var song: Song?
    private var reported: Int?

    /// In seconds; takes in what `playback` says, when that has changed.
    func seconds(for playback: any PlayerSource) -> Double {
        let stopped = playback.playState == .stopped
        let seconds = stopped ? 0 : playback.position
        let playing = playback.song
        if reported == nil || playing != song || stopped {
            clock.seek(to: seconds)
        } else if seconds != reported {
            clock.report(seconds)
        }
        clock.setPlaying(playback.playState == .playing)
        song = playing
        reported = seconds
        return clock.position()
    }

    /// The user seeked to `seconds`.
    func seek(to seconds: Int) {
        clock.seek(to: seconds)
    }
}

/// Shuffle · previous · play/pause · next · repeat, always left to right.
struct TransportControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let playback = model.playback
        HStack {
            ModeToggle(
                systemImage: "shuffle",
                isOn: playback.shuffleMode != .off,
                label: playback.shuffleMode.label
            ) {
                model.toasts.show(playback.cycleShuffle().label)
            }
            Spacer()
            TransportButton(title: "Previous", systemImage: "backward.end.fill", action: playback.previous)
            Spacer()
            PlayPauseButton(playing: playback.playState == .playing, action: playback.playPause) {
                // Only Clementine stops after a song.
                if !playback.isOnPhone {
                    model.session.stopAfterCurrent()
                    model.toasts.show("Stop after this song")
                }
            }
            Spacer()
            TransportButton(title: "Next", systemImage: "forward.end.fill", action: playback.next)
            Spacer()
            ModeToggle(
                systemImage: playback.repeatMode == .track ? "repeat.1" : "repeat",
                isOn: playback.repeatMode != .off,
                label: playback.repeatMode.label
            ) {
                model.toasts.show(playback.cycleRepeat().label)
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
/// Clementine plays on this phone, or the songs kept on it play, it's the phone's volume instead.
struct VolumeSlider: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        HStack(spacing: Metrics.space3) {
            Image(systemName: "speaker.fill")
            if session.isPlayingHere || model.playback.isOnPhone {
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
