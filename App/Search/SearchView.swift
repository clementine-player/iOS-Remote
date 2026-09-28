import ClementineKit
import SwiftUI

/// Searches everything Clementine can: its library and its internet services. Results are in
/// sections by what matched, so a song found by its title is right there to add.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        NavigationStack {
            SearchResultsView()
                .navigationDestination(for: SearchPage.self) { page in
                    SearchListView(page: page, results: model.search)
                }
        }
        .searchable(text: $query, prompt: "Search Clementine")
        .onSubmit(of: .search) {
            model.search.search(query)
        }
    }
}

private struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    private var search: SearchModel { model.search }

    var body: some View {
        SearchSectionsList(results: search)
            .overlay { placeholder }
            .safeAreaInset(edge: .top, spacing: 0) {
                if search.isSearching, let searchedFor = search.searchedFor {
                    ProgressBanner(text: "Searching for “\(searchedFor)”…", fraction: nil)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionChip()
                }
                .sharedBackgroundVisibility(.visible)
            }
    }

    @ViewBuilder
    private var placeholder: some View {
        if !search.isSearching {
            if search.searchedFor == nil {
                ContentUnavailableView(
                    "Search Clementine", systemImage: "magnifyingglass",
                    description: Text("Find music in your library and in Clementine's internet services."))
            } else if search.sections.isEmpty {
                ContentUnavailableView.search(text: search.searchedFor ?? "")
            }
        }
    }
}
