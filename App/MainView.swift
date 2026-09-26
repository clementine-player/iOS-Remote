import ClementineKit
import SwiftUI

/// Clementine's tabs, with the mini player above them.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var playerTransition

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Queue", systemImage: "list.bullet", value: AppModel.Tab.queue) {
                QueueView()
            }
            Tab("Library", systemImage: "square.stack", value: AppModel.Tab.library) {
                LibraryView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppModel.Tab.search, role: .search) {
                SearchView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppModel.Tab.downloads) {
                LibraryPlaceholder(title: "Downloads")
            }
        }
        .tabViewBottomAccessory {
            MiniPlayer {
                model.isPlayerPresented = true
            }
            .matchedTransitionSource(id: "player", in: playerTransition)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .fullScreenCover(isPresented: $model.isPlayerPresented) {
            PlayerView()
                .navigationTransition(.zoom(sourceID: "player", in: playerTransition))
        }
        .sheet(isPresented: $model.isConnectionSheetPresented) {
            ConnectionSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(Palette.surfaceContainerLow)
        }
        .background {
            VolumeButtonsView(model: model)
        }
    }
}

/// Stands in for tabs still to come.
private struct LibraryPlaceholder: View {
    let title: LocalizedStringResource

    var body: some View {
        NavigationStack {
            ContentUnavailableView(String(localized: title), systemImage: "hammer")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .surfaceBackground()
                .navigationTitle(Text(title))
                .connectionToolbar()
        }
    }
}

/// The now-playing strip above the tab bar; tapping it opens the player.
struct MiniPlayer: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let open: () -> Void

    var body: some View {
        let song = session.song
        HStack(spacing: Metrics.space3) {
            Button(action: open) {
                HStack(spacing: Metrics.space3) {
                    Artwork(artData: song?.artData, cornerRadius: Metrics.shapeSmall, markInset: 0.15)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(song?.title ?? String(localized: "No song playing"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.onSurface)
                        if let artist = song?.artist, !artist.isEmpty, placement != .inline {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(Palette.onSurfaceVariant)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(song.map { "\($0.title), \($0.artist)" } ?? String(localized: "No song playing"))
            .accessibilityHint("Opens the player")
            .accessibilityIdentifier("miniPlayer")

            Button(action: session.playPause) {
                Image(systemName: session.playState == .playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Palette.onPrimaryContainer)
                    .frame(width: 36, height: 32)
                    .background(Palette.primaryContainer, in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.playState == .playing ? "Pause" : "Play")
            if placement != .inline {
                Button(action: session.next) {
                    Image(systemName: "forward.end.fill")
                        .foregroundStyle(Palette.onSurface)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next")
            }
        }
        .padding(.horizontal, Metrics.space3)
    }
}
