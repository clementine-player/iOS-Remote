import ClementineKit
import SwiftUI

/// Clementine's tabs, with the mini player above them.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Queue", systemImage: "list.bullet", value: AppModel.Tab.queue) {
                Text("Queue")
            }
            Tab("Library", systemImage: "square.stack", value: AppModel.Tab.library) {
                Text("Library")
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppModel.Tab.search) {
                Text("Search")
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppModel.Tab.downloads) {
                Text("Downloads")
            }
        }
    }
}
