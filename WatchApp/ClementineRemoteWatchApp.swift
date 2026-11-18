import SwiftUI

@main
struct ClementineRemoteWatchApp: App {
    @State private var link = PhoneLink()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NowPlayingView()
                .environment(link)
                .tint(Palette.primary)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                link.startRefreshing()
            } else {
                link.stopRefreshing()
            }
        }
    }
}
