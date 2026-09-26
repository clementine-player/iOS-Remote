import ClementineKit
import SwiftUI

/// A round tile with a glyph: a host, an artist, an album.
struct IconTile: View {
    let systemImage: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45))
            .foregroundStyle(Palette.onSurface)
            .frame(width: size, height: size)
            .background(Palette.secondaryContainer, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A song's cover art, square with rounded corners; the Clementine mark stands in when there's
/// none. Covers crossfade when the song changes.
struct Artwork: View {
    let artData: Data?
    var cornerRadius: CGFloat = Metrics.radiusXL
    /// How far the mark is inset, as a fraction of the size, when there's no cover.
    var markInset: CGFloat = 0.1

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Palette.surfaceContainerHighest
                if let image = ArtCache.shared.image(for: artData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                        .id(artData)
                } else {
                    Image("ClementineMark")
                        .resizable()
                        .scaledToFit()
                        .padding(geometry.size.width * markInset)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.75), value: artData)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityLabel("Cover art")
    }
}

/// Decoded covers, so each is decoded once.
@MainActor
final class ArtCache {
    static let shared = ArtCache()
    private let cache = NSCache<NSData, UIImage>()

    func image(for data: Data?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        if let image = cache.object(forKey: data as NSData) {
            return image
        }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: data as NSData)
        return image
    }
}

/// The big play/pause control. Its corners tighten while pressed. A long press toggles stopping
/// after the current song.
struct PlayPauseButton: View {
    let playing: Bool
    var width: CGFloat = 96
    var height: CGFloat = 72
    var iconSize: CGFloat = 36
    let action: () -> Void
    var longPress: (() -> Void)?

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PlayPauseStyle(width: width, height: height))
        .simultaneousGesture(LongPressGesture().onEnded { _ in longPress?() })
        .accessibilityLabel(playing ? "Pause" : "Play")
        .accessibilityAction(named: "Stop after this song") { longPress?() }
        .accessibilityIdentifier("playPause")
    }
}

private struct PlayPauseStyle: ButtonStyle {
    let width: CGFloat
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let radius = min(height / 2, configuration.isPressed ? 16 : Metrics.radiusXL)
        configuration.label
            .foregroundStyle(Palette.onPrimaryContainer)
            .frame(width: width, height: height)
            .background(Palette.primaryContainer, in: .rect(cornerRadius: radius))
            .contentShape(.rect(cornerRadius: radius))
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// A shuffle or repeat toggle: coloured when on.
struct ModeToggle: View {
    let systemImage: String
    let isOn: Bool
    let label: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(isOn ? Palette.primary : Palette.onSurfaceVariant)
                .frame(width: 48, height: 48)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// A filter chip, to pick one of several (playlists).
struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.space2) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .textStyle(.labelLarge)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Palette.onSecondaryContainer : Palette.onSurfaceVariant)
            .padding(.horizontal, Metrics.space4)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: Metrics.shapeSmall)
                    .fill(isSelected ? Palette.secondaryContainer : .clear)
                RoundedRectangle(cornerRadius: Metrics.shapeSmall)
                    .strokeBorder(isSelected ? .clear : Palette.outline)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A media row: a thumbnail, the title, a meta line, and something at the end.
struct MediaRow<Leading: View>: View {
    let title: String
    let meta: String
    var trailing: String?
    var playing = false
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: Metrics.space4) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Metrics.space2) {
                    if playing {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(Palette.primary)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .accessibilityLabel("Playing")
                    }
                    Text(title)
                        .textStyle(.bodyLarge)
                        .fontWeight(playing ? .medium : .regular)
                        .foregroundStyle(playing ? Palette.primary : Palette.onSurface)
                        .lineLimit(1)
                }
                if !meta.isEmpty {
                    Text(meta)
                        .textStyle(.bodyMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .textStyle(.labelMedium)
                    .monospacedDigit()
                    .foregroundStyle(Palette.onSurfaceVariant)
            }
        }
        .contentShape(.rect)
    }
}

/// The 48-point thumbnail of a song row.
struct SongThumbnail: View {
    var systemImage = "music.note"

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(Palette.onSurfaceVariant)
            .frame(width: 48, height: 48)
            .background(Palette.surfaceContainerHighest, in: .rect(cornerRadius: Metrics.shapeSmall))
            .accessibilityHidden(true)
    }
}

/// The Clementine being controlled, at the top right of each tab; opens the connection sheet.
struct ConnectionChip: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session

    var body: some View {
        let online = session.status == .connected
        Button {
            model.isConnectionSheetPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: online ? "desktopcomputer" : "wifi.exclamationmark")
                    .foregroundStyle(online ? Palette.primary : Palette.onErrorContainer)
                Text(online ? session.hostName : String(localized: "Reconnecting…"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: 160)
                    .fixedSize()
            }
            .padding(.horizontal, 4)
            .foregroundStyle(online ? Palette.onSurface : Palette.onErrorContainer)
        }
        .tint(online ? nil : Palette.errorContainer)
        .accessibilityLabel(online ? "Clementine on \(session.hostName)" : "Reconnecting to Clementine")
        .accessibilityIdentifier("connectionChip")
    }
}

extension View {
    /// Clementine's background for a screen.
    func surfaceBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Palette.surface)
    }

    /// Puts the connection chip in the toolbar.
    func connectionToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionChip()
            }
            .sharedBackgroundVisibility(.visible)
        }
    }
}

/// Times as Clementine shows them: m:ss, or h:mm:ss.
func formatTime(_ seconds: Int) -> String {
    let seconds = abs(seconds)
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
    }
    return String(format: "%d:%02d", minutes, seconds % 60)
}

/// Bytes in binary units: "3.2 MiB".
func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
}

extension ShuffleMode {
    var label: LocalizedStringResource {
        switch self {
        case .off: "Don't shuffle"
        case .all: "Shuffle all"
        case .insideAlbum: "Shuffle tracks in this album"
        case .albums: "Shuffle albums"
        }
    }
}

extension RepeatMode {
    var label: LocalizedStringResource {
        switch self {
        case .off: "Don't repeat"
        case .track: "Repeat track"
        case .album: "Repeat album"
        case .playlist: "Repeat playlist"
        }
    }
}
