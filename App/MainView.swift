import ClementineKit
import SwiftUI

/// Clementine's tabs, with the mini player above them. Without Clementine, to play what's on this
/// phone, On this phone says so, and the other tabs say they need Clementine.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Namespace private var playerTransition

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Queue", systemImage: "list.bullet", value: AppModel.Tab.queue) {
                NeedsClementine { QueueView() }
            }
            Tab("Library", systemImage: "square.stack", value: AppModel.Tab.library) {
                NeedsClementine { LibraryView() }
            }
            // Only Clementine that can be browsed has it.
            if session.canBrowse {
                Tab("Internet", systemImage: "globe", value: AppModel.Tab.internet) {
                    NeedsClementine { InternetView() }
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppModel.Tab.search, role: .search) {
                NeedsClementine { SearchView() }
            }
            Tab(downloadsTitle, systemImage: downloadsImage, value: AppModel.Tab.downloads) {
                DownloadsView()
                    .safeAreaInset(edge: .top) {
                        if model.isWithoutClementine {
                            NotReachableBanner()
                        }
                    }
            }
        }
        .tabViewBottomAccessory {
            MiniPlayer {
                model.isPlayerPresented = true
            }
            .matchedTransitionSource(id: "player", in: playerTransition)
        }
        .onChange(of: session.canBrowse) { _, canBrowse in
            if !canBrowse, model.selectedTab == .internet {
                model.selectedTab = .queue
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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
        .sheet(isPresented: $model.isOutputSheetPresented) {
            OutputSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(Palette.surfaceContainerLow)
        }
        .background {
            VolumeButtonsView(model: model)
        }
    }

    /// The Downloads tab's name: On phone (or On iPad) once it has the music kept on the device.
    private var downloadsTitle: String {
        guard model.isOnThisPhone else { return String(localized: "Downloads") }
        return UIDevice.current.userInterfaceIdiom == .pad
            ? String(localized: "On iPad", comment: "The tab with the music saved on the iPad, as opposed to Clementine on the computer. Keep it short: it's a tab label, under an icon, beside four others.")
            : String(localized: "On phone", comment: "The tab with the music saved on the phone, as opposed to Clementine on the computer. Keep it short: it's a tab label, under an icon, beside four others.")
    }

    private var downloadsImage: String {
        guard model.isOnThisPhone else { return "arrow.down.circle" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }
}

/// A tab that needs Clementine: without it, says so, with Connect.
private struct NeedsClementine<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: Content

    var body: some View {
        if model.isWithoutClementine {
            ContentUnavailableView {
                Label(notReachable, systemImage: "desktopcomputer")
            } actions: {
                Button("Connect", action: model.connectFromPhone)
                    .buttonStyle(.borderedProminent)
                    .filledButtonTint()
            }
            .surfaceBackground()
        } else {
            content
        }
    }
}

private var notReachable: String {
    String(localized: "Clementine isn't reachable", comment: "Banner: the app can't connect to Clementine on the computer.")
}

/// Says Clementine isn't connected, so what's on this phone plays, with Connect.
private struct NotReachableBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Metrics.space3) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(Palette.onSurfaceVariant)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(notReachable)
                    .textStyle(.labelLarge)
                Text(String(localized: "Playing what's on this phone", comment: "Banner, under \"Clementine isn't reachable\"."))
                    .textStyle(.bodyMedium)
                    .foregroundStyle(Palette.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            Button("Connect", action: model.connectFromPhone)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("notReachableConnect")
        }
        .padding(.vertical, Metrics.space3)
        .padding(.leading, Metrics.space4)
        .padding(.trailing, Metrics.space3)
        .background(Palette.surfaceContainerHigh, in: .rect(cornerRadius: Metrics.shapeMedium))
        .padding(.horizontal, Metrics.space4)
        .padding(.bottom, Metrics.space2)
        .background(Palette.surface)
    }
}

/// The now-playing strip above the tab bar; tapping it opens the player. It shows the songs kept
/// on this phone while they play.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let open: () -> Void

    var body: some View {
        let playback = model.playback
        let song = playback.song
        HStack(spacing: Metrics.space3) {
            Button(action: open) {
                HStack(spacing: Metrics.space3) {
                    Artwork(song: song, cornerRadius: Metrics.shapeSmall, markInset: 0.15)
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

            if session.hasOtherOutputs, !playback.isOnPhone, placement != .inline {
                OutputButton(size: 32) { model.isOutputSheetPresented = true }
            }

            Button(action: playback.playPause) {
                Image(systemName: playback.playState == .playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Palette.onPrimaryContainer)
                    .frame(width: 36, height: 32)
                    .background(Palette.primaryContainer, in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.playState == .playing ? "Pause" : "Play")
            if placement != .inline {
                Button(action: playback.next) {
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
