import ClementineKit
import OSLog
import SwiftUI

/// Clementine's library on the phone: whether it's there, downloading it, and browsing it.
@MainActor
@Observable
final class LibraryModel {
    enum Status: Equatable {
        case unknown
        /// Not on the phone yet.
        case missing
        /// Downloading: the fraction done, when known.
        case downloading(Double?)
        /// Downloaded, and being indexed.
        case optimizing
        case ready
    }

    private static let log = Logger(subsystem: "org.clementine-player.remote", category: "Library")

    private(set) var status = Status.unknown
    /// Bumped when the library changes, so screens load it again.
    private(set) var revision = 0

    /// Searching the library, as the Search tab searches Clementine.
    let search: LibrarySearch

    private let store: LibraryStore
    private unowned let model: AppModel
    private var downloadTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        let support = URL.applicationSupportDirectory
        store = LibraryStore(directory: support)
        search = LibrarySearch(store: store, model: model)
    }

    /// Checks for the connected Clementine's library.
    func prepare() async {
        guard downloadTask == nil else { return }
        let exists = await store.prepare(for: model.session.endpoint?.host ?? "", settings: model.settings)
        status = exists ? .ready : .missing
        revision += 1
    }

    func download() {
        guard downloadTask == nil, let endpoint = model.session.endpoint else { return }
        if model.settings.wifiOnly, !model.network.isOnWiFi {
            model.toasts.show(DownloadFailure.onlyOnWiFi.message)
            return
        }
        status = .downloading(nil)
        let authCode = model.session.authCode
        downloadTask = Task {
            // Progress arrives in order, and all of it before the result.
            let (updates, continuation) = AsyncStream.makeStream(of: LibraryStore.Progress.self)
            let shown = Task {
                for await progress in updates {
                    show(progress)
                }
            }
            var failure: DownloadFailure?
            do {
                try await store.download(from: endpoint, authCode: authCode) { continuation.yield($0) }
            } catch {
                failure = (error as? DownloadFailure) ?? .connection
            }
            continuation.finish()
            await shown.value
            if let failure {
                model.toasts.show("Couldn't download the library: \(String(localized: failure.message))")
                status = await store.exists ? .ready : .missing
            } else {
                status = .ready
            }
            revision += 1
            downloadTask = nil
        }
    }

    private func show(_ progress: LibraryStore.Progress) {
        guard downloadTask != nil else { return }
        switch progress {
        case .downloading(let bytes, let total):
            status = .downloading(total > 0 ? min(1, Double(bytes) / Double(total)) : nil)
        case .optimizing:
            status = .optimizing
        }
    }

    func level(below opened: BrowseItem?) async -> BrowseLevel? {
        guard status == .ready else { return nil }
        let settings = model.settings
        do {
            return try await store.level(below: opened, grouping: settings.libraryGrouping, sorting: settings.librarySorting)
        } catch {
            Self.log.error("Couldn't read the library: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Adds the songs of [items] to [target], by default the playlist selected in the queue,
    /// doing [action].
    func add(_ items: [BrowseItem], to target: PlaylistTarget = .selected, action: AddAction = .append) async {
        let settings = model.settings
        guard let urls = try? await store.songURLs(of: items, grouping: settings.libraryGrouping, sorting: settings.librarySorting),
              !urls.isEmpty, let playlist = await model.playlist(for: target) else { return }
        model.session.add(urls: urls, to: playlist.id, action: action)
        model.showAdded(urls.count, to: playlist)
    }

    /// The URLs of the songs [items] are or group.
    func songURLs(of items: [BrowseItem]) async -> [String] {
        let settings = model.settings
        return (try? await store.songURLs(of: items, grouping: settings.libraryGrouping, sorting: settings.librarySorting)) ?? []
    }
}

/// Searching the library on the phone. It matches as Clementine's global search does, and its
/// results are shown the same way, in sections.
@MainActor
@Observable
final class LibrarySearch: SearchResults {
    private(set) var sections = SearchSections()
    /// What the results are for; nil before searching.
    private(set) var searchedFor: String?
    private(set) var revision = 0
    let icons: [String: UIImage] = [:]

    private let store: LibraryStore
    private unowned let model: AppModel

    init(store: LibraryStore, model: AppModel) {
        self.store = store
        self.model = model
    }

    func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        let found = text.isEmpty ? SearchSections() : ((try? await store.search(text)) ?? SearchSections())
        guard !Task.isCancelled else { return }
        sections = found
        searchedFor = text.isEmpty ? nil : text
        revision += 1
    }

    func level(below opened: BrowseItem) async -> BrowseLevel? {
        try? await store.searchLevel(below: opened, sorting: model.settings.librarySorting)
    }

    func add(_ items: [BrowseItem], to target: PlaylistTarget, action: AddAction) async {
        let urls = await songURLs(of: items)
        guard !urls.isEmpty, let playlist = await model.playlist(for: target) else { return }
        model.session.add(urls: urls, to: playlist.id, action: action)
        model.showAdded(urls.count, to: playlist)
    }

    var download: (([BrowseItem]) async -> Void)? {
        { [weak self] items in
            guard let self else { return }
            model.downloads.download(urls: await songURLs(of: items))
        }
    }

    private func songURLs(of items: [BrowseItem]) async -> [String] {
        (try? await store.searchSongURLs(of: items, sorting: model.settings.librarySorting)) ?? []
    }
}

extension DownloadFailure {
    var message: LocalizedStringResource {
        switch self {
        case .onlyOnWiFi: "Downloads are only allowed on Wi-Fi"
        case .connection: "Couldn't connect to Clementine"
        case .forbidden: "Clementine doesn't allow downloads. Turn them on in its Network Remote settings."
        case .wrongAuthCode: "Enter the auth code shown in Clementine's Network Remote settings."
        case .notLocalNetwork: "Clementine only accepts connections from its local network."
        case .tooManyWrongAuthCodes(let retryAfter):
            "Too many wrong auth codes. Clementine won't check another from this phone for \(retryAfter.waitDescription)."
        case .insufficientSpace: "There isn't enough space on this phone"
        case .cantSave: "Couldn't save the file"
        case .corrupt: "The library Clementine sent is damaged"
        case .cancelled: "Download canceled"
        }
    }
}

extension Duration? {
    /// How long Clementine said to wait, or "a while" if it didn't.
    var waitDescription: String {
        self?.waitDescription() ?? String(localized: "a while")
    }
}
