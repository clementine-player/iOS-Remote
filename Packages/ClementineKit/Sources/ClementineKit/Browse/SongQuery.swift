import Foundation

/// What the items of a level are.
public enum ItemKind: Sendable, Hashable {
    /// Where search results came from (the library, an internet service).
    case source
    case artist, album, genre, year
    case song
}

/// An item of the library or search results: a group of songs (an artist, an album…) or a song.
public struct BrowseItem: Sendable, Hashable {
    /// How deep it is: 0 for the top level.
    public var level: Int
    /// The values of the fields grouped by, down to this item's level.
    public var selection: [String]
    public var kind: ItemKind
    /// The song's URL, for a song; one of the group's songs' URLs otherwise.
    public var url: String
    public var artist: String
    public var album: String
    /// For a group, how many items are below it.
    public var itemCount: Int?

    /// This item's own value, such as the artist's name; empty when unknown.
    public var value: String {
        selection.last ?? ""
    }
}

/// A level of items, below [opened] (the top level when nil).
public struct BrowseLevel: Sendable, Hashable {
    public var opened: BrowseItem?
    public var kind: ItemKind
    public var items: [BrowseItem]
}

/// Browses a table of songs level by level, grouping by one field per level: the Android app's
/// DynamicSongQuery. The last field is always the songs' titles.
struct SongQuery {
    /// The fields grouped by, top down, ending with "title".
    let fields: [String]
    let sorting: LibrarySorting
    let table: String
    /// A condition every row must meet, if any.
    var hiddenWhere = ""
    /// The table to read instead of [table] when filtering for [text], if filtering is possible.
    var matching: ((String) -> String)?
    /// Whether the table's URLs are encoded, as the library's are.
    var decodesURLs = true

    var songLevel: Int { fields.count - 1 }

    func kind(ofLevel level: Int) -> ItemKind {
        if level == songLevel {
            return .song
        }
        switch fields[level] {
        case "search_provider": return .source
        case "album": return .album
        case "genre": return .genre
        case "year": return .year
        default: return .artist
        }
    }

    /// The items of [level] within [selection], matching [filter].
    func items(in database: Database, level: Int, selection: [String], filter: String = "") throws -> [BrowseItem] {
        var from = table
        if !filter.isEmpty, let matching {
            from = matching(filter)
        }
        let isSongLevel = level == songLevel
        var sql = "SELECT 0 AS _id"
        for field in fields {
            sql += ", \(field)"
        }
        sql += ", CAST(filename AS TEXT), artist, album FROM \(from)"
        sql += whereClause(selection)
        if isSongLevel {
            sql += " ORDER BY album, disc, track \(sorting.rawValue)"
        } else {
            sql += " GROUP BY \(fields[level]) ORDER BY \(fields[level]) \(sorting.rawValue)"
        }

        return try database.query(sql, selection).map { row in
            let values = (0..<fields.count).map { row[$0 + 1] ?? "" }
            let itemSelection = Array(values[0...level])
            var item = BrowseItem(
                level: level,
                selection: itemSelection,
                kind: kind(ofLevel: level),
                url: decodesURLs ? Self.decode(row[fields.count + 1] ?? "") : row[fields.count + 1] ?? "",
                artist: row[fields.count + 2] ?? "",
                album: row[fields.count + 3] ?? "")
            if !isSongLevel {
                item.itemCount = try count(in: database, selection: itemSelection)
            }
            return item
        }
    }

    /// How many distinct items are below [selection].
    func count(in database: Database, selection: [String]) throws -> Int {
        let sql = "SELECT COUNT(DISTINCT(\(fields[selection.count]))) FROM \(table)" + whereClause(selection)
        let value = try database.query(sql, selection).first?.first ?? nil
        return value.flatMap { Int($0) } ?? 0
    }

    private func whereClause(_ selection: [String]) -> String {
        var conditions = selection.indices.map { "\(fields[$0]) = ?" }
        if !hiddenWhere.isEmpty {
            conditions.append(hiddenWhere)
        }
        return conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    }

    /// Clementine stores URLs encoded; the app sends them back decoded, keeping any "+".
    static func decode(_ url: String) -> String {
        url.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding ?? url
    }
}

/// Opens levels of a [SongQuery] and finds the songs below items.
struct SongBrowser {
    let query: SongQuery

    /// The level below [opened], or the top level for nil, matching [filter].
    func level(below opened: BrowseItem?, filter: String = "", in database: Database) throws -> BrowseLevel {
        let level = opened.map { $0.level + 1 } ?? 0
        let items = try query.items(
            in: database, level: level, selection: opened?.selection ?? [], filter: filter)
        return BrowseLevel(opened: opened, kind: query.kind(ofLevel: level), items: items)
    }

    /// The songs [items] are, or group.
    func songs(_ items: [BrowseItem], in database: Database) throws -> [BrowseItem] {
        try items.flatMap { item in
            item.level == query.songLevel
                ? [item]
                : try query.items(in: database, level: query.songLevel, selection: item.selection)
        }
    }
}
