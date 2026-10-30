import Foundation

/// When a rule asks Clementine for its songs again.
public enum RefreshPolicy: String, Sendable, CaseIterable {
    /// Once, when the rule is made: a song, album or artist.
    case never
    /// Every time the phone connects, at most hourly: hand-edited playlists.
    case onConnect = "on_connect"
    /// Once `refreshIntervalHours` have passed: smart playlists.
    case interval
    /// Once `refreshAfterPercent` of its songs have been played on the phone.
    case afterListening = "after_listening"
}

/// How a play on the phone ended, as Clementine's PlayOutcome.
public enum PlayOutcome: String, Sendable, CaseIterable {
    case completed
    case skipped
}

/// What to keep on the phone: a source on one Clementine, when to refresh it, and how much of
/// it. `serverID` is the Clementine's server_id, and `sourceID` is opaque, as Clementine gave it.
/// Quality fields left nil use the phone's sync settings.
public struct SyncRule: Sendable, Equatable {
    public var id: Int64
    public var serverID: String
    public var sourceID: String
    public var title: String
    /// What the source is, for the rule's icon.
    public var kind: Pb_Remote_SyncSourceKind
    public var refreshPolicy: RefreshPolicy
    public var refreshIntervalHours: Int
    public var refreshAfterPercent: Int
    /// 0: no limit.
    public var limitItems: Int
    public var limitBytes: Int64
    public var quality: Pb_Remote_SyncQuality?
    public var lossless: Pb_Remote_SyncLossless?
    public var maxBitrateKbps: Int?
    public var preferredMIMEType: String?
    /// For random sources: sent with each request until the rule refreshes.
    public var seed: Int64
    /// Where it shows in the list, and which rule's songs fit first in the budget.
    public var position: Int
    /// 0 until it first syncs.
    public var lastSynced: Date?

    public init(
        id: Int64 = 0, serverID: String, sourceID: String, title: String, kind: Pb_Remote_SyncSourceKind,
        refreshPolicy: RefreshPolicy, refreshIntervalHours: Int = 0, refreshAfterPercent: Int = 0,
        limitItems: Int = 0, limitBytes: Int64 = 0, quality: Pb_Remote_SyncQuality? = nil,
        lossless: Pb_Remote_SyncLossless? = nil,
        maxBitrateKbps: Int? = nil, preferredMIMEType: String? = nil, seed: Int64 = 0,
        position: Int = 0, lastSynced: Date? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.sourceID = sourceID
        self.title = title
        self.kind = kind
        self.refreshPolicy = refreshPolicy
        self.refreshIntervalHours = refreshIntervalHours
        self.refreshAfterPercent = refreshAfterPercent
        self.limitItems = limitItems
        self.limitBytes = limitBytes
        self.quality = quality
        self.lossless = lossless
        self.maxBitrateKbps = maxBitrateKbps
        self.preferredMIMEType = preferredMIMEType
        self.seed = seed
        self.position = position
        self.lastSynced = lastSynced
    }
}

/// A song on the phone. `itemKey` and `version` are Clementine's; `path` is the file's path
/// relative to the synced songs' folder, so it survives the app's container moving. `metadata` is
/// the SongMetadata from the manifest, serialized, so the offline library reads it rather than
/// the file's tags.
public struct SyncedItem: Sendable, Equatable {
    public var serverID: String
    public var itemKey: String
    public var version: String
    public var path: String
    public var mimeType: String
    public var sizeBytes: Int64
    public var delivery: Pb_Remote_SyncDelivery
    /// The cover's `SyncedArt.artKey`, or nil for none.
    public var artKey: String?
    public var metadata: Data
    public var pinned: Bool
    public var added: Date

    public init(
        serverID: String, itemKey: String, version: String, path: String, mimeType: String,
        sizeBytes: Int64, delivery: Pb_Remote_SyncDelivery, artKey: String?, metadata: Data, pinned: Bool = false,
        added: Date
    ) {
        self.serverID = serverID
        self.itemKey = itemKey
        self.version = version
        self.path = path
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.delivery = delivery
        self.artKey = artKey
        self.metadata = metadata
        self.pinned = pinned
        self.added = added
    }
}

/// A cover, kept once however many songs share it. `artKey` is the SHA-256 Clementine sent.
public struct SyncedArt: Sendable, Equatable {
    public var artKey: String
    public var path: String
    public var sizeBytes: Int64

    public init(artKey: String, path: String, sizeBytes: Int64) {
        self.artKey = artKey
        self.path = path
        self.sizeBytes = sizeBytes
    }
}

/// A song played on the phone, kept until Clementine accepts it.
public struct PlayLogEntry: Sendable, Equatable {
    public var id: Int64
    public var serverID: String
    public var itemKey: String
    /// When it started, to the second.
    public var played: Date
    public var listenedMs: Int64
    public var outcome: PlayOutcome
    /// 0 to 1, if rated on the phone.
    public var rating: Float?

    public init(
        id: Int64 = 0, serverID: String, itemKey: String, played: Date, listenedMs: Int64,
        outcome: PlayOutcome, rating: Float? = nil
    ) {
        self.id = id
        self.serverID = serverID
        self.itemKey = itemKey
        self.played = played
        self.listenedMs = listenedMs
        self.outcome = outcome
        self.rating = rating
    }
}

/// The phone's record of what it syncs: rules, the songs and covers on the phone, which rules
/// want which songs, and plays made on the phone. Every row belongs to one Clementine, by
/// server_id, so another Clementine's songs are kept apart. A song is stored once however many
/// rules want it. The same tables as the Android client's.
public actor SyncStore {
    private let database: Database

    /// Opens the store at `url`, creating it if need be, or an in-memory one when nil.
    public init(url: URL?) throws {
        database = try Database(path: url?.path)
        try database.execute("PRAGMA foreign_keys = ON")
        let version = try database.rows("PRAGMA user_version").first?.first?.integer ?? 0
        if version < 1 {
            try database.execute(Self.schema)
            try database.execute("PRAGMA user_version = 1")
        }
        // Later versions migrate from here, keeping what's on the phone.
    }

    private static let schema = """
        CREATE TABLE rules (
          id INTEGER PRIMARY KEY,
          server_id TEXT NOT NULL,
          source_id TEXT NOT NULL,
          title TEXT NOT NULL,
          kind INTEGER NOT NULL,
          refresh_policy TEXT NOT NULL,
          refresh_interval_hours INTEGER NOT NULL DEFAULT 0,
          refresh_after_percent INTEGER NOT NULL DEFAULT 0,
          limit_items INTEGER NOT NULL DEFAULT 0,
          limit_bytes INTEGER NOT NULL DEFAULT 0,
          quality INTEGER,
          lossless INTEGER,
          max_bitrate_kbps INTEGER,
          preferred_mime_type TEXT,
          seed INTEGER NOT NULL DEFAULT 0,
          position INTEGER NOT NULL DEFAULT 0,
          last_synced_at INTEGER NOT NULL DEFAULT 0,
          UNIQUE (server_id, source_id));
        CREATE TABLE items (
          server_id TEXT NOT NULL,
          item_key TEXT NOT NULL,
          version TEXT NOT NULL,
          path TEXT NOT NULL,
          mime_type TEXT NOT NULL,
          size_bytes INTEGER NOT NULL,
          delivery INTEGER NOT NULL,
          art_key TEXT,
          metadata BLOB NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0,
          added_at INTEGER NOT NULL,
          PRIMARY KEY (server_id, item_key));
        -- Which rules want which songs, in each rule's order. A song no rule wants, and that
        -- isn't pinned, is deleted.
        CREATE TABLE rule_items (
          rule_id INTEGER NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
          server_id TEXT NOT NULL,
          item_key TEXT NOT NULL,
          position INTEGER NOT NULL,
          PRIMARY KEY (rule_id, item_key),
          FOREIGN KEY (server_id, item_key) REFERENCES items(server_id, item_key) ON DELETE CASCADE);
        CREATE INDEX rule_items_by_item ON rule_items (server_id, item_key);
        CREATE TABLE art (
          art_key TEXT PRIMARY KEY,
          path TEXT NOT NULL,
          size_bytes INTEGER NOT NULL);
        CREATE TABLE play_log (
          id INTEGER PRIMARY KEY,
          server_id TEXT NOT NULL,
          item_key TEXT NOT NULL,
          played_at INTEGER NOT NULL,
          listened_ms INTEGER NOT NULL,
          outcome TEXT NOT NULL,
          rating REAL);
        """

    // MARK: Rules

    @discardableResult
    public func addRule(_ rule: SyncRule) throws -> Int64 {
        try database.run(
            "INSERT INTO rules (\(Self.ruleColumns)) VALUES (\(Self.placeholders(Self.ruleColumnCount)))",
            Self.values(rule))
        return database.lastInsertRowID
    }

    public func updateRule(_ rule: SyncRule) throws {
        let assignments = Self.ruleColumns.split(separator: ",").map {
            "\($0.trimmingCharacters(in: .whitespaces)) = ?"
        }.joined(separator: ", ")
        try database.run(
            "UPDATE rules SET \(assignments) WHERE id = ?", Self.values(rule) + [.integer(rule.id)])
    }

    /// Removes the rule; its songs go once no other rule wants them (see `unwantedItems`).
    public func removeRule(id: Int64) throws {
        try database.run("DELETE FROM rules WHERE id = ?", [.integer(id)])
    }

    public func rules(serverID: String) throws -> [SyncRule] {
        try database.rows(
            "SELECT id, \(Self.ruleColumns) FROM rules WHERE server_id = ? ORDER BY position, id",
            [.text(serverID)]
        ).map(Self.rule)
    }

    public func rule(id: Int64) throws -> SyncRule? {
        try database.rows(
            "SELECT id, \(Self.ruleColumns) FROM rules WHERE id = ?", [.integer(id)]
        ).first.map(Self.rule)
    }

    // MARK: Songs

    /// Adds the song, or replaces it with a new version, keeping which rules want it.
    public func putItem(_ item: SyncedItem) throws {
        let values = Self.values(item)
        try database.run(
            """
            UPDATE items SET version = ?, path = ?, mime_type = ?, size_bytes = ?, delivery = ?,
              art_key = ?, metadata = ?, pinned = ?, added_at = ?
            WHERE server_id = ? AND item_key = ?
            """,
            Array(values[2...]) + Array(values[..<2]))
        if database.changes == 0 {
            try database.run(
                "INSERT INTO items (\(Self.itemColumns)) VALUES (\(Self.placeholders(values.count)))",
                values)
        }
    }

    public func item(serverID: String, itemKey: String) throws -> SyncedItem? {
        try database.rows(
            "SELECT \(Self.itemColumns) FROM items WHERE server_id = ? AND item_key = ?",
            [.text(serverID), .text(itemKey)]
        ).first.map(Self.item)
    }

    public func items(serverID: String) throws -> [SyncedItem] {
        try database.rows(
            "SELECT \(Self.itemColumns) FROM items WHERE server_id = ? ORDER BY added_at, item_key",
            [.text(serverID)]
        ).map(Self.item)
    }

    public func setPinned(serverID: String, itemKey: String, pinned: Bool) throws {
        try database.run(
            "UPDATE items SET pinned = ? WHERE server_id = ? AND item_key = ?",
            [.integer(pinned ? 1 : 0), .text(serverID), .text(itemKey)])
    }

    public func removeItem(serverID: String, itemKey: String) throws {
        try database.run(
            "DELETE FROM items WHERE server_id = ? AND item_key = ?",
            [.text(serverID), .text(itemKey)])
    }

    /// Sets the songs `ruleID` wants, in its order, replacing what it wanted before. Each must be
    /// in the store already.
    public func setRuleItems(ruleID: Int64, serverID: String, itemKeys: [String]) throws {
        try database.execute("BEGIN")
        do {
            try database.run("DELETE FROM rule_items WHERE rule_id = ?", [.integer(ruleID)])
            for (position, itemKey) in itemKeys.enumerated() {
                try database.run(
                    "INSERT INTO rule_items (rule_id, server_id, item_key, position) VALUES (?, ?, ?, ?)",
                    [.integer(ruleID), .text(serverID), .text(itemKey), .integer(Int64(position))])
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    /// The songs `ruleID` wants that are on the phone, in its order.
    public func ruleItems(ruleID: Int64) throws -> [SyncedItem] {
        try database.rows(
            """
            SELECT \(Self.itemColumns.split(separator: ",").map { "items." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
            FROM rule_items JOIN items USING (server_id, item_key)
            WHERE rule_id = ? ORDER BY position
            """,
            [.integer(ruleID)]
        ).map(Self.item)
    }

    /// Songs on the phone that no rule wants and that aren't pinned: the ones to delete.
    public func unwantedItems(serverID: String) throws -> [SyncedItem] {
        try database.rows(
            """
            SELECT \(Self.itemColumns) FROM items WHERE server_id = ? AND pinned = 0 AND NOT EXISTS
              (SELECT 1 FROM rule_items r WHERE r.server_id = items.server_id AND r.item_key = items.item_key)
            """,
            [.text(serverID)]
        ).map(Self.item)
    }

    /// How much space the songs and covers on the phone take, across every Clementine.
    public func usedBytes() throws -> Int64 {
        try database.rows(
            "SELECT (SELECT IFNULL(SUM(size_bytes), 0) FROM items) + (SELECT IFNULL(SUM(size_bytes), 0) FROM art)"
        ).first?.first?.integer ?? 0
    }

    // MARK: Covers

    public func putArt(_ art: SyncedArt) throws {
        try database.run(
            "INSERT OR REPLACE INTO art (art_key, path, size_bytes) VALUES (?, ?, ?)",
            [.text(art.artKey), .text(art.path), .integer(art.sizeBytes)])
    }

    public func art(key: String) throws -> SyncedArt? {
        try database.rows(
            "SELECT art_key, path, size_bytes FROM art WHERE art_key = ?", [.text(key)]
        ).first.map(Self.art)
    }

    /// Covers no song on the phone uses any more.
    public func unusedArt() throws -> [SyncedArt] {
        try database.rows(
            """
            SELECT art_key, path, size_bytes FROM art
            WHERE art_key NOT IN (SELECT art_key FROM items WHERE art_key IS NOT NULL)
            """
        ).map(Self.art)
    }

    public func removeArt(key: String) throws {
        try database.run("DELETE FROM art WHERE art_key = ?", [.text(key)])
    }

    // MARK: Plays

    @discardableResult
    public func logPlay(_ entry: PlayLogEntry) throws -> Int64 {
        try database.run(
            """
            INSERT INTO play_log (server_id, item_key, played_at, listened_ms, outcome, rating)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(entry.serverID), .text(entry.itemKey),
             .integer(Int64(entry.played.timeIntervalSince1970)), .integer(entry.listenedMs),
             .text(entry.outcome.rawValue), entry.rating.map { .real(Double($0)) } ?? .null])
        return database.lastInsertRowID
    }

    /// Plays not yet accepted by `serverID`, oldest first.
    public func playLog(serverID: String) throws -> [PlayLogEntry] {
        try database.rows(
            """
            SELECT id, server_id, item_key, played_at, listened_ms, outcome, rating FROM play_log
            WHERE server_id = ? ORDER BY played_at, id
            """,
            [.text(serverID)]
        ).map { row in
            PlayLogEntry(
                id: row[0].integer ?? 0, serverID: row[1].text ?? "", itemKey: row[2].text ?? "",
                played: Date(timeIntervalSince1970: TimeInterval(row[3].integer ?? 0)),
                listenedMs: row[4].integer ?? 0,
                outcome: PlayOutcome(rawValue: row[5].text ?? "") ?? .completed,
                rating: row[6].real.map { Float($0) })
        }
    }

    /// Drops plays Clementine has accepted.
    public func removePlays(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try database.run(
            "DELETE FROM play_log WHERE id IN (\(Self.placeholders(ids.count)))",
            ids.map { .integer($0) })
    }

    // MARK: Rows

    private static let ruleColumns = """
        server_id, source_id, title, kind, refresh_policy, refresh_interval_hours,
        refresh_after_percent, limit_items, limit_bytes, quality, lossless, max_bitrate_kbps,
        preferred_mime_type, seed, position, last_synced_at
        """
    private static let ruleColumnCount = 16

    private static let itemColumns = """
        server_id, item_key, version, path, mime_type, size_bytes, delivery, art_key, metadata,
        pinned, added_at
        """

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func optional(_ value: Int?) -> Database.Value {
        value.map { .integer(Int64($0)) } ?? .null
    }

    /// One of the protocol's enums, saved as its number: nil when there's none, or it's one this
    /// version doesn't know.
    private static func enumValue<Value: RawRepresentable>(_ value: Database.Value) -> Value? where Value.RawValue == Int {
        value.integer.flatMap { Value(rawValue: Int($0)) }
    }

    private static func milliseconds(_ date: Date?) -> Int64 {
        date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
    }

    private static func date(_ value: Database.Value) -> Date? {
        guard let milliseconds = value.integer, milliseconds != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private static func values(_ rule: SyncRule) -> [Database.Value] {
        [.text(rule.serverID), .text(rule.sourceID), .text(rule.title), .integer(Int64(rule.kind.rawValue)),
         .text(rule.refreshPolicy.rawValue), .integer(Int64(rule.refreshIntervalHours)),
         .integer(Int64(rule.refreshAfterPercent)), .integer(Int64(rule.limitItems)),
         .integer(rule.limitBytes), optional(rule.quality?.rawValue), optional(rule.lossless?.rawValue),
         optional(rule.maxBitrateKbps), rule.preferredMIMEType.map { .text($0) } ?? .null,
         .integer(rule.seed), .integer(Int64(rule.position)), .integer(milliseconds(rule.lastSynced))]
    }

    private static func rule(_ row: [Database.Value]) -> SyncRule {
        SyncRule(
            id: row[0].integer ?? 0, serverID: row[1].text ?? "", sourceID: row[2].text ?? "",
            title: row[3].text ?? "", kind: Self.enumValue(row[4]) ?? .unspecified,
            refreshPolicy: RefreshPolicy(rawValue: row[5].text ?? "") ?? .never,
            refreshIntervalHours: Int(row[6].integer ?? 0),
            refreshAfterPercent: Int(row[7].integer ?? 0), limitItems: Int(row[8].integer ?? 0),
            limitBytes: row[9].integer ?? 0, quality: Self.enumValue(row[10]),
            lossless: Self.enumValue(row[11]), maxBitrateKbps: row[12].integer.map { Int($0) },
            preferredMIMEType: row[13].text, seed: row[14].integer ?? 0,
            position: Int(row[15].integer ?? 0), lastSynced: date(row[16]))
    }

    private static func values(_ item: SyncedItem) -> [Database.Value] {
        [.text(item.serverID), .text(item.itemKey), .text(item.version), .text(item.path),
         .text(item.mimeType), .integer(item.sizeBytes), .integer(Int64(item.delivery.rawValue)),
         item.artKey.map { .text($0) } ?? .null, .blob(item.metadata),
         .integer(item.pinned ? 1 : 0), .integer(milliseconds(item.added))]
    }

    private static func item(_ row: [Database.Value]) -> SyncedItem {
        SyncedItem(
            serverID: row[0].text ?? "", itemKey: row[1].text ?? "", version: row[2].text ?? "",
            path: row[3].text ?? "", mimeType: row[4].text ?? "", sizeBytes: row[5].integer ?? 0,
            delivery: Self.enumValue(row[6]) ?? .unspecified, artKey: row[7].text, metadata: row[8].blob ?? Data(),
            pinned: row[9].integer == 1, added: date(row[10]) ?? Date(timeIntervalSince1970: 0))
    }

    private static func art(_ row: [Database.Value]) -> SyncedArt {
        SyncedArt(artKey: row[0].text ?? "", path: row[1].text ?? "", sizeBytes: row[2].integer ?? 0)
    }
}
