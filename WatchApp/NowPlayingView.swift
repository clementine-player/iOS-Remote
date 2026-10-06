import ClementineWatch
import SwiftUI

/// The watch's one screen: what Clementine plays, with its controls, or why it can't show it.
struct NowPlayingView: View {
    @Environment(PhoneLink.self) private var link

    var body: some View {
        NavigationStack {
            if let state = link.nowPlaying, state.connection == .connected {
                PlayerView(state: state)
            } else if link.nowPlaying?.connection == .connecting {
                ProgressView("Connecting…")
            } else {
                NotConnectedView()
            }
        }
    }
}

/// The song's cover filling the screen, with the song and the controls over it. The Digital Crown
/// sets Clementine's volume, shown beside the crown while it turns, as the watch's own Now Playing
/// does. With the wrist down, the cover fades to black, leaving the song and the buttons.
private struct PlayerView: View {
    let state: WatchNowPlaying
    @Environment(PhoneLink.self) private var link
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var crownVolume = 0.0
    @State private var isTurningCrown = false
    @State private var isVolumeShown = false
    @State private var sendingVolume: Task<Void, Never>?
    @State private var hidingVolume: Task<Void, Never>?

    var body: some View {
        ZStack {
            Backdrop(cover: state.cover, hasSong: state.hasSong)
                .opacity(isLuminanceReduced ? 0 : 1)
                .ignoresSafeArea()
            controls
        }
        .animation(.easeInOut(duration: 0.4), value: isLuminanceReduced)
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            // VoiceOver can't turn the crown: swiping up and down changes the volume instead.
            switch direction {
            case .increment: crownVolume = min(100, crownVolume + 5)
            case .decrement: crownVolume = max(0, crownVolume - 5)
            @unknown default: break
            }
        }
        .accessibilityValue("Volume \(Int(crownVolume.rounded()))%")
        .toolbar {
            if state.showsLove, state.hasSong, !isLuminanceReduced {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        link.send(.love)
                    } label: {
                        Label("Love", systemImage: state.isLoved ? "heart.fill" : "heart")
                            .foregroundStyle(Palette.onPrimary)
                    }
                    .disabled(state.isLoved)
                }
            }
        }
        .focusable()
        .digitalCrownRotation(
            detent: $crownVolume, from: 0, through: 100, by: 1, sensitivity: .medium, isContinuous: false,
            isHapticFeedbackEnabled: true
        ) { _ in
            isTurningCrown = true
        } onIdle: {
            isTurningCrown = false
        }
        .digitalCrownAccessory {
            VolumeMeter(volume: Int(crownVolume.rounded()))
        }
        .digitalCrownAccessory(isVolumeShown ? .visible : .hidden)
        .onChange(of: state.volume, initial: true) { _, volume in
            if !isTurningCrown { crownVolume = Double(volume) }
        }
        .onChange(of: crownVolume) { _, volume in
            setVolume(Int(volume.rounded()))
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            SongInfo(state: state)
            if state.length > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProgressView(value: Double(state.position(at: context.date)), total: Double(state.length))
                        .tint(Palette.primary)
                }
                .opacity(isLuminanceReduced ? 0 : 1)
            }
            // Kept with the wrist down, dimmed, so they're where they were on raising it.
            Transport(isPlaying: state.isPlaying)
                .opacity(isLuminanceReduced ? 0.6 : 1)
        }
        // Down to the bottom of the screen, which watchOS keeps clear otherwise.
        .padding(.bottom, 8)
        .ignoresSafeArea(edges: .bottom)
    }

    /// Keeps the volume beside the crown a moment after it stops, as the system's does.
    private func hideVolumeSoon() {
        hidingVolume?.cancel()
        hidingVolume = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { isVolumeShown = false }
        }
    }

    /// Sends the volume once the crown pauses a moment, rather than at every step.
    private func setVolume(_ volume: Int) {
        guard volume != state.volume else { return }
        isVolumeShown = true
        hideVolumeSoon()
        sendingVolume?.cancel()
        sendingVolume = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            link.send(.setVolume(volume))
        }
    }
}

/// The title and the artist, over the bottom of the cover.
private struct SongInfo: View {
    let state: WatchNowPlaying
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.hasSong ? state.title : String(localized: "No song playing"))
                .font(.headline)
                .foregroundStyle(.white)
            if state.hasSong {
                Text(state.artist)
                    .font(.footnote)
                    .foregroundStyle(Palette.primary)
            }
        }
        .lineLimit(1)
        .opacity(isLuminanceReduced ? 0.6 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clear of the screen's rounded edge.
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The cover, filling the screen, darkened at the top for the clock and at the bottom for the
/// song and the controls. A music note for a song without one, as on the phone, and the
/// Clementine mark with nothing playing.
private struct Backdrop: View {
    let cover: Data?
    let hasSong: Bool

    var body: some View {
        ZStack {
            Color.black
            if let cover, let image = UIImage(data: cover) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Palette.surfaceContainerHighest
                Group {
                    if hasSong {
                        Image(systemName: "music.note")
                            .font(.system(size: 56))
                            .foregroundStyle(Palette.onSurfaceVariant)
                    } else {
                        Image("ClementineMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80)
                    }
                }
                .offset(y: -64)
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.6), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(0.85), location: 0.85),
                ],
                startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Previous, play/pause and next, always left to right.
private struct Transport: View {
    let isPlaying: Bool
    @Environment(PhoneLink.self) private var link

    var body: some View {
        HStack {
            Button("Previous", systemImage: "backward.end.fill") { link.send(.previous) }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 52)
            Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill") {
                link.send(.playPause)
            }
            .font(.title)
            .foregroundStyle(Palette.onPrimaryContainer)
            .buttonStyle(.plain)
            .frame(width: 76, height: 60)
            .background(Palette.primaryContainer, in: .rect(cornerRadius: 20))
            Button("Next", systemImage: "forward.end.fill") { link.send(.next) }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Clementine's volume, beside the Digital Crown while it turns: a speaker over a level that
/// fills from the bottom.
private struct VolumeMeter: View {
    let volume: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption2)
                .foregroundStyle(Palette.primary)
            Capsule()
                .fill(Palette.surfaceContainerHighest)
                .frame(width: 6, height: 44)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Palette.primary)
                        .frame(height: 44 * CGFloat(volume) / 100)
                }
        }
        .accessibilityHidden(true)
    }
}

/// Not connected: why, and Connect when the phone knows a Clementine.
private struct NotConnectedView: View {
    @Environment(PhoneLink.self) private var link

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image("ClementineMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if canConnect {
                    Button("Connect") { link.connect() }
                        .tint(Palette.primaryFill)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var hostName: String { link.nowPlaying?.hostName ?? "" }

    private var canConnect: Bool { !link.isPhoneUnreachable && !hostName.isEmpty }

    private var title: LocalizedStringKey {
        link.isPhoneUnreachable ? "Can't reach your iPhone" : "Not connected"
    }

    private var message: LocalizedStringKey {
        if link.isPhoneUnreachable {
            "Clementine Remote on your iPhone connects to Clementine for this watch. Keep your iPhone nearby."
        } else if link.nowPlaying == nil {
            "Open Clementine Remote on your iPhone."
        } else if hostName.isEmpty {
            "Connect to Clementine in Clementine Remote on your iPhone first."
        } else if link.couldNotConnect {
            "Couldn't reach Clementine on \(hostName)."
        } else {
            "Clementine on \(hostName)"
        }
    }
}
