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

public enum SyncError: Error, Equatable, LocalizedError {
    case insufficientSpace

    public var errorDescription: String? {
        switch self {
        case .insufficientSpace: "Not enough free space on this device"
        }
    }
}

/// Brings what's on the phone in line with the rules for one Clementine: asks for each rule's
/// manifest, downloads the songs that are new or changed into `folder`, with their covers, and
/// deletes the songs that no rule wants any more. A song in several rules is downloaded once, and a
/// cover many songs share is too. Conversions come later.
///
/// `supportedFormats` are the types the phone plays, as for streaming (`Renderer.formats`).
/// `progress` hears how many of a rule's songs to download have been, before the first and after
/// each one.
public struct SyncEngine: Sendable {
    public let store: SyncStore
    /// The synced songs' folder, which songs' paths are relative to.
    public let folder: URL
    public let supportedFormats: [String]
    private let now: @Sendable () -> Date
    private let progress: @Sendable (_ ruleID: Int64, SyncProgress) async -> Void

    public init(
        store: SyncStore, folder: URL, supportedFormats: [String],
        now: @escaping @Sendable () -> Date = { Date() },
        progress: @escaping @Sendable (_ ruleID: Int64, SyncProgress) async -> Void = { _, _ in }
    ) {
        self.store = store
        self.folder = folder
        self.supportedFormats = supportedFormats
        self.now = now
        self.progress = progress
    }

    public func sync(_ connection: some SyncConnection) async throws -> SyncResult {
        let serverID = connection.serverID
        var results: [Int64: RuleResult] = [:]
        for rule in try await store.rules(serverID: serverID) {
            try Task.checkCancellation()
            // A rule kept as it is has its songs once it has synced. The other policies refresh
            // on every sync for now; intervals and listening come later.
            if rule.refreshPolicy == .never, rule.lastSynced != nil { continue }
            do {
                results[rule.id] = try await sync(rule, over: connection)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                // URLSession throws URLError(.cancelled) rather than CancellationError when
                // Syncer.stop() cancels an active transfer; normalize so removeUnwanted() is skipped.
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                results[rule.id] = .failed(error.localizedDescription)
            }
        }

        // Only once every rule has had its say: a song moving from one rule to another stays.
        return SyncResult(rules: results, removed: try await Self.removeUnwanted(store: store, serverID: serverID, folder: folder))
    }

    /// Deletes [serverID]'s songs in [folder] that no rule wants, as after a rule is removed.
    /// Returns how many.
    public static func removeUnwanted(store: SyncStore, serverID: String, folder: URL) async throws -> Int {
        var removed = 0
        for item in try await store.unwantedItems(serverID: serverID) {
            // Already gone, say if the user deleted it: forget it all the same.
            try? FileManager.default.removeItem(at: folder.appending(path: item.path))
            try await store.removeItem(serverID: serverID, itemKey: item.itemKey)
            removed += 1
        }
        for art in try await store.unusedArt() {
            try? FileManager.default.removeItem(at: folder.appending(path: art.path))
            try await store.removeArt(key: art.artKey)
        }
        // Sweep abandoned `.partial/` transfers older than 7 days so interrupted downloads don't accumulate.
        let partialDir = folder.appending(path: ".partial", directoryHint: .isDirectory)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: partialDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            for entry in entries {
                if let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   modified < cutoff {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
        }
        return removed
    }

    private func sync(_ rule: SyncRule, over connection: some SyncConnection) async throws -> RuleResult {
        let manifest = try await connection.manifest(request(for: rule))
        switch manifest.state {
        case .needsSetup: return .needsSetup(manifest.message)
        case .gone: return .gone
        default: break
        }

        var wanted: [(item: Pb_Remote_SyncItem, have: SyncedItem?, needsDownload: Bool)] = []
        // A song a playlist has twice is kept once, where it first comes.
        var seen = Set<String>()
        for item in manifest.items where seen.insert(item.itemKey).inserted {
            let have = try await store.item(serverID: rule.serverID, itemKey: item.itemKey)
            // Verify the file still exists on disk so missing tracks are re-downloaded even when
            // the stored version matches.
            let onDisk = have.map { FileManager.default.fileExists(atPath: folder.appending(path: $0.path).path) } ?? false
            let needsDownload = have?.version != item.version || !onDisk
            wanted.append((item, have, needsDownload))
        }
        let total = wanted.count(where: \.needsDownload)
        if total > 0 { await progress(rule.id, SyncProgress(done: 0, total: total)) }
        var downloaded = 0
        var keys: [String] = []
        do {
            for (item, have, needsDownload) in wanted {
                try Task.checkCancellation()
                if needsDownload {
                    try await download(item, serverID: rule.serverID, replacing: have, over: connection)
                    downloaded += 1
                    await progress(rule.id, SyncProgress(done: downloaded, total: total))
                } else if var have, have.artKey != (item.hasArt ? item.art.key : nil) {
                    // The same song with another cover, or one kept before covers were.
                    have.artKey = await art(item, over: connection)
                    try await store.putItem(have)
                }
                keys.append(item.itemKey)
            }
        } catch {
            // Keep the songs downloaded so far as well as those it had, so a sync cut short
            // carries on next time rather than starting again, provided the rule still exists.
            // Re-checking avoids foreign-key failures if Syncer.remove() deleted the rule.
            if (try await store.rule(id: rule.id)) != nil {
                var kept = try await store.ruleItems(ruleID: rule.id).map(\.itemKey)
                kept += keys.filter { !kept.contains($0) }
                try await store.setRuleItems(ruleID: rule.id, serverID: rule.serverID, itemKeys: kept)
            }
            throw error
        }
        // Guard against a concurrent Syncer.remove() deleting the rule before committing items.
        guard (try await store.rule(id: rule.id)) != nil else {
            throw CancellationError()
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

        // Deterministic partial file so interrupted downloads can resume with HTTP Range/If-Range
        // without leaving incomplete files at the final song path.
        let partial = folder.appending(path: SyncFiles.partialName(serverID: serverID, itemKey: item.itemKey, version: item.version))
        try files.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existingPartial = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let remaining = max(0, item.sizeBytes - existingPartial)
        if remaining > 0, let free = LibraryStore.freeSpace(at: folder), free < remaining {
            throw SyncError.insufficientSpace
        }
        do {
            try await connection.download(item.url, to: partial)
            if files.fileExists(atPath: file.path) {
                _ = try files.replaceItemAt(file, withItemAt: partial)
            } else {
                try files.moveItem(at: partial, to: file)
            }
            try? files.removeItem(at: partial.appendingPathExtension("etag"))
        } catch SyncConnectionError.status(let code) where (400..<500).contains(code) {
            try? files.removeItem(at: partial)
            try? files.removeItem(at: partial.appendingPathExtension("etag"))
            throw SyncConnectionError.status(code)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Keep partial data for transient network failures so the next sync can resume; discard
            // only if partial file is empty.
            let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 {
                try? files.removeItem(at: partial)
                try? files.removeItem(at: partial.appendingPathExtension("etag"))
            }
            throw error
        }

        // Persist the new database row before deleting any superseded file at a different path.
        try await store.putItem(
            SyncedItem(
                serverID: serverID, itemKey: item.itemKey, version: item.version, path: path,
                mimeType: item.mimeType, sizeBytes: item.sizeBytes, delivery: item.delivery,
                artKey: await art(item, over: connection), metadata: try song.serializedData(),
                pinned: have?.pinned ?? false, added: have?.added ?? now()))
        if let have, have.path != path {
            try? files.removeItem(at: folder.appending(path: have.path))
        }
    }

    /// The key of `item`'s cover, downloading it if the phone doesn't have it yet; nil if it has
    /// none, or it couldn't be downloaded, so it's tried again next time. A song without a cover
    /// of its own from Clementine shows the one in its file, if any.
    private func art(_ item: Pb_Remote_SyncItem, over connection: some SyncConnection) async -> String? {
        guard item.hasArt, let path = SyncFiles.artPath(key: item.art.key) else { return nil }
        let key = item.art.key
        let file = folder.appending(path: path)
        let files = FileManager.default
        // Check the file on disk too in case the cached cover was purged outside SyncStore.
        if (try? await store.art(key: key)) != nil, files.fileExists(atPath: file.path) { return key }
        let partial = file.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
        do {
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await connection.download(item.art.url, to: partial)
            if files.fileExists(atPath: file.path) {
                _ = try files.replaceItemAt(file, withItemAt: partial)
            } else {
                try files.moveItem(at: partial, to: file)
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try await store.putArt(SyncedArt(artKey: key, path: path, sizeBytes: Int64(size)))
            return key
        } catch {
            try? files.removeItem(at: partial)
            return nil
        }
    }
}
