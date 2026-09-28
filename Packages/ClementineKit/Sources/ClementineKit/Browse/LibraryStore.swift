import Foundation
import OSLog

/// Why downloading the library or songs failed.
public enum DownloadFailure: Error, Sendable, Equatable {
    /// Downloads are allowed only on Wi-Fi, and the phone isn't on it.
    case onlyOnWiFi
    /// Couldn't connect, or the connection dropped.
    case connection
    /// Clementine doesn't allow downloads.
    case forbidden
    /// Clementine didn't accept the auth code.
    case wrongAuthCode
    /// Not enough space on the phone.
    case insufficientSpace
    /// Couldn't write the file.
    case cantSave
    /// The library that arrived isn't a usable database.
    case corrupt
    case cancelled

    private static let log = Logger(subsystem: "org.clementine-player.remote", category: "Downloads")

    /// Why Clementine closed the connection, as a failure.
    init(_ disconnect: Pb_Remote_ResponseDisconnect) {
        let reason = disconnect.hasReasonDisconnect ? disconnect.reasonDisconnect : nil
        Self.log.error("Clementine closed the download: \(reason.map { String(describing: $0) } ?? "no reason", privacy: .public)")
        switch reason {
        case .downloadForbidden: self = .forbidden
        case .wrongAuthCode, .notAuthenticated: self = .wrongAuthCode
        case .serverShutdown, nil: self = .connection
        }
    }
}

/// Clementine's library, copied to the phone: an SQLite database Clementine sends as it is, then
/// indexed for searching.
public actor LibraryStore {
    public enum Progress: Sendable, Equatable {
        /// Bytes received of the total, when known.
        case downloading(bytes: Int64, total: Int64)
        /// Downloaded; indexing it.
        case optimizing
    }

    public let fileURL: URL
    private var database: Database?

    /// A library kept in [directory].
    public init(directory: URL) {
        fileURL = directory.appending(path: "library.db")
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Keeps the library only if it came from [host], and returns whether there is one. A library
    /// from another Clementine is no use: its songs' URLs are on another computer.
    public func prepare(for host: String, settings: Settings) -> Bool {
        if settings.libraryHost != host {
            settings.libraryHost = host
            delete()
        }
        return exists
    }

    public func delete() {
        database = nil
        columns = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The level below [opened] (the top level for nil), grouped by [grouping].
    public func level(below opened: BrowseItem?, grouping: LibraryGrouping, sorting: LibrarySorting) throws -> BrowseLevel {
        try browser(grouping, sorting).level(below: opened, in: open())
    }

    /// The URLs of the songs [items] are or group.
    public func songURLs(of items: [BrowseItem], grouping: LibraryGrouping, sorting: LibrarySorting) throws -> [String] {
        try browser(grouping, sorting).songs(items, in: open()).map(\.url).filter { !$0.isEmpty }
    }

    private func browser(_ grouping: LibraryGrouping, _ sorting: LibrarySorting) -> SongBrowser {
        SongBrowser(query: SongQuery(fields: grouping.fields, sorting: sorting, table: "songs"))
    }

    // MARK: - Searching

    /// Songs are grouped by their album artist, else their artist, as Clementine groups albums.
    private static let groupArtist = "IFNULL(NULLIF(albumartist, ''), artist)"

    /// The songs matching [text] as Clementine's global search matches them (each word starts a
    /// word of some field), in sections as its results are shown. Artists and albums of the
    /// sections open with [searchLevel(below:sorting:)], not the library's grouping.
    public func search(_ text: String) throws -> SearchSections {
        let database = try open()
        let match = try fullTextQuery(text, columns: fullTextColumns(database))
        guard !match.isEmpty else { return SearchSections() }
        let rows = try database.query("""
            SELECT \(Self.groupArtist), album, title, artist, CAST(filename AS TEXT)
            FROM songs_fts WHERE songs_fts MATCH ?
            """, [match])
        return SearchSections(query: text, songs: rows.map { row in
            let values = row.map { $0 ?? "" }
            return SearchCandidate(
                item: BrowseItem(
                    level: 2, selection: Array(values[0...2]), kind: .song, url: SongQuery.decode(values[4]),
                    artist: values[3], album: values[1]),
                artist: values[3])
        })
    }

    /// The level below [opened], an artist or album of [search(_:)].
    public func searchLevel(below opened: BrowseItem, sorting: LibrarySorting) throws -> BrowseLevel {
        try searchBrowser(sorting).level(below: opened, in: open())
    }

    /// The URLs of the songs [items] of [search(_:)] are or group.
    public func searchSongURLs(of items: [BrowseItem], sorting: LibrarySorting) throws -> [String] {
        try searchBrowser(sorting).songs(items, in: open()).map(\.url).filter { !$0.isEmpty }
    }

    private func searchBrowser(_ sorting: LibrarySorting) -> SongBrowser {
        SongBrowser(query: SongQuery(fields: [Self.groupArtist, "album", "title"], sorting: sorting, table: "songs"))
    }

    /// [text] as a full-text query, as Clementine makes one: every word must start a word of some
    /// field, or of the field it's prefixed with ("artist:satie"). Words are quoted, so none is an
    /// operator such as OR.
    func fullTextQuery(_ text: String, columns: Set<String>) -> String {
        text.split(whereSeparator: \.isWhitespace).flatMap { token -> [String] in
            var token = Substring(token)
            var column = ""
            if let colon = token.firstIndex(of: ":") {
                let name = token[..<colon].lowercased()
                if columns.contains(name) {
                    column = name + ":"
                }
                token = token[token.index(after: colon)...]
            }
            // A field's word can't be quoted, but after it, isn't an operator either.
            return token.split { !$0.isLetter && !$0.isNumber }.map { column.isEmpty ? "\"\($0)*\"" : "\(column)\($0)*" }
        }.joined(separator: " ")
    }

    private var columns: Set<String>?

    private func fullTextColumns(_ database: Database) throws -> Set<String> {
        if let columns {
            return columns
        }
        let columns = Set(try database.query("PRAGMA table_info(songs_fts)").compactMap { $0[1]?.lowercased() })
        self.columns = columns
        return columns
    }

    private func open() throws -> Database {
        if let database {
            return database
        }
        let database = try Database(path: fileURL.path, readOnly: true)
        self.database = database
        return database
    }

    /// Downloads the library from Clementine, replacing the one on the phone.
    public func download(
        from endpoint: Endpoint, authCode: Int32, progress: @escaping @Sendable (Progress) -> Void
    ) async throws(DownloadFailure) {
        let partial = fileURL.deletingLastPathComponent().appending(path: "library.db.part")
        try? FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        let channel = MessageChannel(endpoint: endpoint)
        do {
            try await channel.open()
            try await channel.send(Messages.connect(authCode: authCode, sendPlaylistSongs: false, downloader: true))
            try await channel.send(RemoteMessage(.getLibrary))
        } catch {
            channel.cancel()
            throw .connection
        }
        defer { channel.cancel() }

        var file: FileHandle?
        defer { try? file?.close() }
        var received: Int64 = 0
        while true {
            let message: RemoteMessage
            do {
                message = try await channel.receive()
            } catch {
                throw Task.isCancelled ? .cancelled : .connection
            }
            if message.type == .disconnect {
                throw DownloadFailure(message.responseDisconnect)
            }
            guard message.type == .libraryChunk else { continue }
            let chunk = message.responseLibraryChunk
            if file == nil {
                // Twice the size: indexing needs as much again.
                if let free = Self.freeSpace(at: partial), free < Int64(chunk.size) * 2 {
                    throw .insufficientSpace
                }
                guard FileManager.default.createFile(atPath: partial.path, contents: nil),
                      let handle = try? FileHandle(forWritingTo: partial) else { throw .cantSave }
                file = handle
            }
            do {
                try file?.write(contentsOf: chunk.data)
            } catch {
                throw .cantSave
            }
            received += Int64(chunk.data.count)
            progress(.downloading(bytes: received, total: Int64(chunk.size)))
            if chunk.chunkNumber == chunk.chunkCount {
                break
            }
        }
        try? file?.close()
        file = nil
        try? await channel.send(RemoteMessage(.disconnect))

        progress(.optimizing)
        do {
            try Self.optimize(partial)
        } catch {
            throw .corrupt
        }
        database = nil
        columns = nil
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: partial)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            do {
                try FileManager.default.moveItem(at: partial, to: fileURL)
            } catch {
                throw .cantSave
            }
        }
    }

    /// Drops unavailable songs, and adds the full-text index and the indices browsing uses.
    static func optimize(_ url: URL) throws {
        let database = try Database(path: url.path)
        guard try database.query("PRAGMA integrity_check(1)").first?.first == "ok" else {
            throw DatabaseError(message: "The library is damaged")
        }
        try database.execute("DELETE FROM songs WHERE unavailable <> 0")
        let columns = try database.query("PRAGMA table_info(songs)").compactMap { $0[1] }
        try database.execute("""
            DROP TABLE IF EXISTS songs_fts;
            CREATE VIRTUAL TABLE songs_fts USING fts3(\(columns.joined(separator: ", ")));
            INSERT INTO songs_fts SELECT * FROM songs;
            CREATE INDEX IF NOT EXISTS songs_artist ON songs (artist);
            CREATE INDEX IF NOT EXISTS songs_album ON songs (artist, album);
            CREATE INDEX IF NOT EXISTS songs_title ON songs (artist, album, title);
            """)
    }

    public static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
