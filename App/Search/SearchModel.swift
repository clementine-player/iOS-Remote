import ClementineKit
import SwiftUI

/// Searches with Clementine's global search, and keeps the results.
@MainActor
@Observable
final class SearchModel {
    /// What was searched for last; nil before the first search.
    private(set) var searchedFor: String?
    private(set) var isSearching = false
    /// Bumped when results are ready, so screens load them.
    private(set) var revision = 0
    private(set) var icons: [String: UIImage] = [:]

    private let store = SearchStore()
    private unowned let model: AppModel
    private let messages: AsyncStream<RemoteMessage>.Continuation

    init(model: AppModel) {
        self.model = model
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteMessage.self)
        messages = continuation
        // Clementine's messages, handled one at a time, in order.
        Task { [store, weak self] in
            for await message in stream {
                guard let finished = try? await store.handle(message) else { continue }
                let icons = await store.icons
                self?.finished(finished, icons: icons)
            }
        }
        model.session.addObserver { message in
            if message.type == .globalSearchStatus || message.type == .globalSearchResult {
                continuation.yield(message)
            }
        }
    }

    func search(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searchedFor = text
        isSearching = true
        model.session.search(text)
    }

    private func finished(_ id: Int32, icons: [String: Data]) {
        isSearching = false
        self.icons = icons.compactMapValues(UIImage.init(data:))
        revision += 1
    }

    func level(below opened: BrowseItem?) async -> BrowseLevel? {
        let settings = model.settings
        return try? await store.level(below: opened, grouping: settings.libraryGrouping, sorting: settings.librarySorting)
    }

    /// Adds the songs of [items] to the playlist playing.
    func add(_ items: [BrowseItem], to target: PlaylistTarget = .playing) async {
        let settings = model.settings
        guard let songs = try? await store.songs(of: items, grouping: settings.libraryGrouping, sorting: settings.librarySorting),
              !songs.isEmpty, let playlist = await model.playlist(for: target) else { return }
        model.session.add(songs: songs, to: playlist.id)
        model.showAdded(songs.count, to: playlist, target: target)
    }
}
