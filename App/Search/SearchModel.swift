import ClementineKit
import SwiftUI

/// Searches with Clementine's global search, and keeps the results.
@MainActor
@Observable
final class SearchModel: SearchResults {
    /// What was searched for last; nil before the first search.
    private(set) var searchedFor: String?
    private(set) var isSearching = false
    /// The results so far, in sections.
    private(set) var sections = SearchSections()
    /// Bumped when results arrive, so screens reload them.
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
                // Results are shown as they come; most searches find songs in the library quickly
                // and radio streams slowly.
                let finished = (try? await store.handle(message)) != nil
                let sections = await store.sections()
                let icons = await store.icons
                self?.update(sections, icons: icons, finished: finished)
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

    private func update(_ sections: SearchSections, icons: [String: Data], finished: Bool) {
        if finished {
            isSearching = false
        }
        guard sections != self.sections || icons.count != self.icons.count else { return }
        self.sections = sections
        self.icons = icons.compactMapValues(UIImage.init(data:))
        revision += 1
    }

    /// The level below [opened], an artist or album of the results.
    func level(below opened: BrowseItem) async -> BrowseLevel? {
        try? await store.level(below: opened, sorting: model.settings.librarySorting)
    }

    /// Results of the global search are added to playlists, not downloaded.
    var download: (([BrowseItem]) async -> Void)? { nil }

    /// Adds the songs of [items] to [target], by default the playlist selected in the queue.
    /// With [playIfStopped], Clementine plays them unless it's playing already, as it does
    /// when you double-click a song in it.
    func add(_ items: [BrowseItem], to target: PlaylistTarget = .selected, playIfStopped: Bool = false) async {
        guard let songs = try? await store.songs(of: items, sorting: model.settings.librarySorting),
              !songs.isEmpty, let playlist = await model.playlist(for: target) else { return }
        model.session.add(songs: songs, to: playlist.id, playIfStopped: playIfStopped)
        model.showAdded(songs.count, to: playlist)
    }
}
