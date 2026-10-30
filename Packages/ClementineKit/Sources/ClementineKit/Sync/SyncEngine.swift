import Foundation

/// How the engine talks to the Clementine it syncs with, while connected to it.
public protocol SyncConnection: Sendable {
    /// The Clementine's server_id.
    var serverID: String { get }

    /// Asks Clementine for a rule's manifest, and waits for it.
    func manifest(_ request: Pb_Remote_RequestSyncManifest) async throws -> Pb_Remote_ResponseSyncManifest

    /// Downloads a path Clementine gave, such as a song's /d/ URL, from its HTTP server to `file`.
    func download(_ path: String, to file: URL) async throws
}

/// What a sync did for each rule.
public struct SyncResult: Sendable, Equatable {
    /// By rule id.
    public var rules: [Int64: RuleResult]
    /// Songs deleted because no rule wants them any more.
    public var removed: Int
}

public enum RuleResult: Sendable, Equatable {
    /// `downloaded` new or changed songs; `skipped` are the songs Clementine left out.
    case synced(songs: Int, downloaded: Int, skipped: Int)
    /// Clementine needs setting up first; the message says how, in the user's language.
    case needsSetup(String)
    /// The rule's source no longer exists on Clementine. Its songs are kept.
    case gone
    /// The rule couldn't sync, for now: it's tried again next time.
    case failed(String)
}

/// Brings what's on the phone in line with the rules for one Clementine: asks for each rule's
/// manifest, downloads the songs that are new or changed into `folder`, and deletes the songs that
/// no rule wants any more. A song in several rules is downloaded once. Covers and conversions come
/// later.
///
/// `supportedFormats` are the types the phone plays, as for streaming (`Renderer.formats`).
public struct SyncEngine: Sendable {
    public let store: SyncStore
    /// The synced songs' folder, which songs' paths are relative to.
    public let folder: URL
    public let supportedFormats: [String]
    private let now: @Sendable () -> Date

    public init(
        store: SyncStore, folder: URL, supportedFormats: [String],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.folder = folder
        self.supportedFormats = supportedFormats
        self.now = now
    }

    public func sync(_ connection: some SyncConnection) async throws -> SyncResult {
        let serverID = connection.serverID
        var results: [Int64: RuleResult] = [:]
        for rule in try await store.rules(serverID: serverID) {
            try Task.checkCancellation()
            do {
                results[rule.id] = try await sync(rule, over: connection)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results[rule.id] = .failed(error.localizedDescription)
            }
        }

        // Only once every rule has had its say: a song moving from one rule to another stays.
        var removed = 0
        for item in try await store.unwantedItems(serverID: serverID) {
            // Already gone, say if the user deleted it: forget it all the same.
            try? FileManager.default.removeItem(at: folder.appending(path: item.path))
            try await store.removeItem(serverID: serverID, itemKey: item.itemKey)
            removed += 1
        }
        return SyncResult(rules: results, removed: removed)
    }

    private func sync(_ rule: SyncRule, over connection: some SyncConnection) async throws -> RuleResult {
        let manifest = try await connection.manifest(request(for: rule))
        switch manifest.state {
        case .needsSetup: return .needsSetup(manifest.message)
        case .gone: return .gone
        default: break
        }

        var downloaded = 0
        var keys: [String] = []
        do {
            for item in manifest.items {
                let have = try await store.item(serverID: rule.serverID, itemKey: item.itemKey)
                if have?.version != item.version {
                    try await download(item, serverID: rule.serverID, replacing: have, over: connection)
                    downloaded += 1
                }
                keys.append(item.itemKey)
            }
        } catch {
            // Keep the songs downloaded so far as well as those it had, so a sync cut short
            // carries on next time rather than starting again.
            var kept = try await store.ruleItems(ruleID: rule.id).map(\.itemKey)
            kept += keys.filter { !kept.contains($0) }
            try await store.setRuleItems(ruleID: rule.id, serverID: rule.serverID, itemKeys: kept)
            throw error
        }
        try await store.setRuleItems(ruleID: rule.id, serverID: rule.serverID, itemKeys: keys)
        var synced = rule
        synced.lastSynced = now()
        try await store.updateRule(synced)
        return .synced(songs: keys.count, downloaded: downloaded, skipped: Int(manifest.skipped))
    }

    private func request(for rule: SyncRule) -> Pb_Remote_RequestSyncManifest {
        var request = Pb_Remote_RequestSyncManifest()
        request.sourceID = rule.sourceID
        request.supportedFormats = supportedFormats.map { type in
            var format = Pb_Remote_AudioFormat()
            format.mimeType = type
            return format
        }
        request.seed = rule.seed
        if rule.limitItems > 0 {
            request.limitItems = Int32(rule.limitItems)
        }
        if rule.limitBytes > 0 {
            request.limitBytes = rule.limitBytes
        }
        return request
    }

    /// Downloads `item`, replacing the older version `have` if there is one.
    private func download(
        _ item: Pb_Remote_SyncItem, serverID: String, replacing have: SyncedItem?,
        over connection: some SyncConnection
    ) async throws {
        let song = item.song
        let directory = SyncFiles.relativeDirectory(song)
        let name = SyncFiles.freeName(
            in: folder, directory: directory, name: SyncFiles.fileName(song, mimeType: item.mimeType),
            own: have?.path)
        let path = directory + name
        let file = folder.appending(path: path)
        let files = FileManager.default
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Downloaded beside it first, so a download cut short leaves no half a song.
        let partial = file.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
        do {
            try await connection.download(item.url, to: partial)
            if files.fileExists(atPath: file.path) {
                _ = try files.replaceItemAt(file, withItemAt: partial)
            } else {
                try files.moveItem(at: partial, to: file)
            }
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }

        if let have, have.path != path {
            try? files.removeItem(at: folder.appending(path: have.path))
        }
        try await store.putItem(
            SyncedItem(
                serverID: serverID, itemKey: item.itemKey, version: item.version, path: path,
                mimeType: item.mimeType, sizeBytes: item.sizeBytes, delivery: item.delivery,
                artKey: nil, metadata: try song.serializedData(), pinned: have?.pinned ?? false,
                added: have?.added ?? now()))
    }
}
