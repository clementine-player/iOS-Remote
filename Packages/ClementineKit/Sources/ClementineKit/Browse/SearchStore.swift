import Foundation

/// The results of Clementine's global search, kept in an in-memory database so they can be
/// browsed like the library: by where they came from, then the library grouping.
public actor SearchStore {
    private let database: Database
    /// The search whose results are kept.
    public private(set) var searchID: Int32?
    /// Each result's full description, by URL, for adding it to a playlist.
    private var songs: [String: SongMetadata] = [:]
    /// Each provider's icon (image data), by name.
    public private(set) var icons: [String: Data] = [:]

    public init() {
        // An in-memory database always opens.
        database = try! Database(path: nil)
        try! database.execute("""
            CREATE TABLE results (
              global_search_id INTEGER NOT NULL, search_query TEXT, search_provider TEXT,
              title TEXT, album TEXT, artist TEXT, albumartist TEXT, track INTEGER, disc INTEGER,
              pretty_year TEXT, year INTEGER, genre TEXT, pretty_length TEXT,
              filename TEXT NOT NULL, is_local INTEGER NOT NULL, filesize INTEGER NOT NULL,
              rating REAL, url TEXT NOT NULL DEFAULT 0);
            CREATE INDEX results_id ON results (global_search_id);
            """)
    }

    /// Follows a message from Clementine. Returns the id of a search that has finished.
    @discardableResult
    public func handle(_ message: RemoteMessage) throws -> Int32? {
        switch message.type {
        case .globalSearchStatus:
            let status = message.responseGlobalSearchStatus
            switch status.status {
            case .globalSearchStarted:
                try start(status.id)
            case .globalSearchFinished:
                if status.id == searchID {
                    return status.id
                }
            }
        case .globalSearchResult:
            try add(message.responseGlobalSearch)
        default:
            break
        }
        return nil
    }

    /// Forgets every result.
    public func reset() throws {
        searchID = nil
        songs = [:]
        try database.execute("DELETE FROM results")
    }

    private func start(_ id: Int32) throws {
        try reset()
        searchID = id
    }

    private func add(_ result: Pb_Remote_ResponseGlobalSearch) throws {
        guard result.id == searchID else { return }
        if !result.searchProviderIcon.isEmpty {
            icons[result.searchProvider] = result.searchProviderIcon
        }
        try database.execute("BEGIN")
        defer { try? database.execute("COMMIT") }
        for song in result.songMetadata {
            try database.run("""
                INSERT INTO results (global_search_id, search_query, search_provider, title, album, artist,
                  albumartist, track, disc, pretty_year, year, genre, pretty_length, filename, is_local,
                  filesize, rating)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .integer(Int64(result.id)), .text(result.query), .text(result.searchProvider),
                    .text(song.title), .text(song.album), .text(song.artist), .text(song.albumartist),
                    .integer(Int64(song.track)), .integer(Int64(song.disc)), .text(song.prettyYear),
                    .integer(Int64(song.prettyYear) ?? -1), .text(song.genre), .text(song.prettyLength),
                    // The URL goes where the library keeps it.
                    .text(song.url), .integer(song.isLocal ? 1 : 0), .integer(Int64(song.fileSize)),
                    .real(Double(song.rating)),
                ])
            songs[song.url] = song
        }
    }

    /// The level below [opened] (the top level, of providers, for nil).
    public func level(below opened: BrowseItem?, grouping: LibraryGrouping, sorting: LibrarySorting) throws -> BrowseLevel? {
        guard let browser = browser(grouping, sorting) else { return nil }
        return try browser.level(below: opened, in: database)
    }

    /// The songs [items] are or group, described in full.
    public func songs(of items: [BrowseItem], grouping: LibraryGrouping, sorting: LibrarySorting) throws -> [SongMetadata] {
        guard let browser = browser(grouping, sorting) else { return [] }
        return try browser.songs(items, in: database).compactMap { songs[$0.url] }
    }

    private func browser(_ grouping: LibraryGrouping, _ sorting: LibrarySorting) -> SongBrowser? {
        guard let searchID else { return nil }
        var query = SongQuery(fields: ["search_provider"] + grouping.fields, sorting: sorting, table: "results")
        query.hiddenWhere = "global_search_id = \(searchID)"
        query.decodesURLs = false
        return SongBrowser(query: query)
    }
}
