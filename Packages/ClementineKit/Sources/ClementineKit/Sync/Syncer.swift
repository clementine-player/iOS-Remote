import Foundation
import Observation
import os
import Synchronization

/// Whether songs can be synced from this Clementine to the phone.
public struct Syncing: Sendable, Equatable {
    /// Whether this Clementine syncs (SERVER_FEATURE_SYNC, with a server id), in a build with the
    /// features still being built. Without, nothing about syncing shows.
    public var supported = false
    /// The Clementine's server_id, which its rules and songs are kept under.
    public var serverID = ""
    /// Whether Clementine's settings let the phone download songs.
    public var downloadsAllowed = false

    public var available: Bool { supported && downloadsAllowed }

    public init(supported: Bool = false, serverID: String = "", downloadsAllowed: Bool = false) {
        self.supported = supported
        self.serverID = serverID
        self.downloadsAllowed = downloadsAllowed
    }

    init(_ info: Pb_Remote_ResponseClementineInfo) {
        self.init(
            supported: TestingFeatures.enabled && info.features.contains(.sync) && !info.serverID.isEmpty,
            serverID: info.serverID, downloadsAllowed: info.allowDownloads)
    }
}

/// A rule, with the songs of it on the phone, and how its last sync went.
public struct KeptRule: Sendable, Equatable, Identifiable {
    public var rule: SyncRule
    public var songs: Int
    public var bytes: Int64
    /// Nil until it syncs while the app runs.
    public var result: RuleResult?
    /// How far the sync running has got with downloading its songs, if it has started.
    public var downloading: SyncProgress?

    public var id: Int64 { rule.id }

    public init(rule: SyncRule, songs: Int, bytes: Int64, result: RuleResult?, downloading: SyncProgress? = nil) {
        self.rule = rule
        self.songs = songs
        self.bytes = bytes
        self.result = result
        self.downloading = downloading
    }
}

/// `done` of the `total` songs a sync has to download.
public struct SyncProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// Syncs the rules for the connected Clementine while the app is connected to it: each time it
/// connects, and when asked ([syncNow]), such as after a rule is made ([keep]) or removed
/// ([remove]), over the networks Download over allows. [BackgroundSync] connects in the
/// background for it.
@MainActor
@Observable
public final class Syncer {
    /// Where syncing stands.
    public struct Status: Sendable, Equatable {
        public var running = false
        /// The last sync's outcome for each rule, by rule id, until the next one.
        public var results: [Int64: RuleResult] = [:]
        /// The last sync couldn't start or finish: there's nowhere to save songs, say.
        public var unavailable = false
        /// The last sync didn't start, because Download over doesn't allow the phone's network.
        public var networkNotAllowed = false
    }

    private static let logger = Logger(subsystem: "org.clementine-player.remote", category: "Syncer")

    public private(set) var status = Status()
    /// The rules for the Clementine connected, or the last one, in their order: read again when
    /// one is made or removed, and after each sync.
    public private(set) var kept: [KeptRule] = []
    /// The rules and synced songs; nil if it couldn't be opened.
    public let store: SyncStore?
    /// The synced songs' folder.
    public let folder: URL
    @ObservationIgnored private let session: RemoteSession
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let manifests = SyncManifests()
    @ObservationIgnored let timeout: Duration
    /// Whether the phone's network is one that Download over allows.
    @ObservationIgnored public var networkAllows: @MainActor (DownloadNetwork) -> Bool = { _ in true }
    /// While set, as during a background sync, only this Clementine syncs: another that connects
    /// is left alone, and doesn't become the one the rules shown are for.
    @ObservationIgnored public var onlyServerID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var mutationGeneration: UInt64 = 0
    @ObservationIgnored private var again = false
    /// The rules the sync running is downloading songs for, by rule id.
    @ObservationIgnored private var progress: [Int64: SyncProgress] = [:]

    public init(
        session: RemoteSession, store: SyncStore?, folder: URL, settings: Settings = Settings(),
        timeout: Duration = ClementineSyncConnection.manifestTimeout
    ) {
        self.session = session
        self.settings = settings
        self.store = store
        self.folder = folder
        self.timeout = timeout
        if FileManager.default.fileExists(atPath: folder.path) {
            Self.excludeFromBackup(folder)
        }
        session.addObserver { [weak self] message in
            self?.handle(message)
        }
        session.addStatusObserver { [weak self] status in
            // Fail pending manifest continuations immediately when the session drops or suspends
            // instead of stalling up to 60s per rule waiting on a dead connection.
            switch status {
            case .disconnected, .suspended, .reconnecting:
                self?.manifests.failAll(SyncConnectionError.notConnected)
            case .connecting, .downloadingData, .connected:
                break
            }
        }
    }

    private func handle(_ message: RemoteMessage) {
        manifests.handle(message)
        // Clementine says what it can do each time the app connects.
        guard message.type == .info else { return }
        if let onlyServerID, session.syncing.serverID != onlyServerID { return }
        if session.syncing.supported {
            settings.syncServerID = session.syncing.serverID
            refresh()
        }
        if session.syncing.available {
            syncNow()
        }
    }

    /// The Clementine the rules shown are for: the one connected, or the last one that synced.
    private var serverID: String {
        session.syncing.supported ? session.syncing.serverID : settings.syncServerID
    }

    /// Reads the rules again, for [kept], such as when they're first shown.
    public func refresh() {
        Task { await readKept() }
    }

    private func readKept() async {
        let serverID = serverID
        guard let store, !serverID.isEmpty else { return }
        let rules: [SyncRule]
        do {
            rules = try await store.rules(serverID: serverID)
        } catch {
            Self.logger.error("Failed to read sync rules for \(serverID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        var kept: [KeptRule] = []
        for rule in rules {
            let songs: [SyncedItem]
            do {
                songs = try await store.ruleItems(ruleID: rule.id)
            } catch {
                Self.logger.error("Failed to read items for rule \(rule.id): \(error.localizedDescription, privacy: .public)")
                songs = []
            }
            kept.append(KeptRule(
                rule: rule, songs: songs.count, bytes: songs.reduce(0) { $0 + $1.sizeBytes },
                result: status.results[rule.id], downloading: progress[rule.id]))
        }
        self.kept = kept
    }

    /// The songs of a rule on this phone, in its order.
    public func songs(_ ruleID: Int64) async -> [KeptSong] {
        guard let store else { return [] }
        do {
            return try await store.ruleItems(ruleID: ruleID).map { KeptSong($0, in: folder) }
        } catch {
            Self.logger.error("Failed to read songs for rule \(ruleID): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // Serialize keep/remove/syncNow sequentially so concurrent keep() calls cannot collide on
    // rule.position and remove() never races an active SyncEngine.
    private func enqueueMutation(_ operation: @escaping @MainActor () async -> Void) {
        let previous = mutationTask
        mutationGeneration &+= 1
        let generation = mutationGeneration
        mutationTask = Task {
            _ = await previous?.result
            await operation()
            if self.mutationGeneration == generation {
                self.mutationTask = nil
            }
        }
    }

    /// Keeps [rules] on the phone, and syncs them. A rule for a source already kept is left as it
    /// is.
    public func keep(_ rules: [SyncRule]) {
        guard let store else { return }
        enqueueMutation { [weak self] in
            guard let self else { return }
            var added = false
            for var rule in rules {
                do {
                    let existing = try await store.rules(serverID: rule.serverID)
                    guard !existing.contains(where: { $0.sourceID == rule.sourceID }) else { continue }
                    rule.position = (existing.map(\.position).max() ?? -1) + 1
                    _ = try await store.addRule(rule)
                    added = true
                } catch {
                    Self.logger.error("Failed to keep rule \(rule.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            if added {
                await self.readKept()
                self.startSync()
            }
        }
    }

    /// Stops keeping a rule, and deletes its songs that nothing else kept has.
    public func remove(_ ruleID: Int64) {
        guard let store else { return }
        enqueueMutation { [weak self] in
            guard let self else { return }
            // Stop and await any running sync before deleting the rule so SyncEngine cannot hit
            // foreign-key failures on rule_items, then resume syncing remaining rules if needed.
            let wasRunning = self.task != nil
            if wasRunning {
                self.stop()
                await activeTaskValue()
            }
            do {
                guard let rule = try await store.rule(id: ruleID) else { return }
                try await store.removeRule(id: ruleID)
                _ = try await SyncEngine.removeUnwanted(store: store, serverID: rule.serverID, folder: self.folder)
            } catch {
                Self.logger.error("Failed to remove rule \(ruleID): \(error.localizedDescription, privacy: .public)")
            }
            self.status.results[ruleID] = nil
            await self.readKept()
            if wasRunning {
                self.startSync()
            }
        }
    }

    /// Syncs now, or once more after the sync that's running.
    public func syncNow() {
        enqueueMutation { [weak self] in
            self?.startSync()
        }
    }

    private func startSync() {
        guard task == nil else {
            again = true
            return
        }
        task = Task {
            await runSyncLoop()
        }
    }

    private func runSyncLoop() async {
        repeat {
            again = false
            await runOnce()
        } while again && !Task.isCancelled
        task = nil
    }

    /// Serializes a background sync using a dedicated [externalSession] onto this single `Syncer`,
    /// guaranteeing at most one `SyncEngine` touches `store` and `folder` at a time. Cancelling
    /// this call cancels whichever sync task is currently running or being waited on.
    func runExternalSync(using externalSession: RemoteSession) async {
        let activeTask = Mutex<Task<Void, Never>?>(nil)
        await withTaskCancellationHandler {
            // Drain any pending foreground mutation or sync task before running on
            // externalSession so only one SyncEngine touches store and folder at once.
            while !Task.isCancelled && (mutationTask != nil || task != nil) {
                if let current = task {
                    activeTask.withLock { $0 = current }
                    if Task.isCancelled { current.cancel() }
                    await current.value
                    activeTask.withLock { $0 = nil }
                } else {
                    await mutationTask?.value
                }
            }
            guard !Task.isCancelled else { return }
            let runner = Task {
                await runOnce(using: externalSession)
            }
            activeTask.withLock { $0 = runner }
            if Task.isCancelled { runner.cancel() }
            task = runner
            await runner.value
            activeTask.withLock { $0 = nil }
            if task == runner {
                task = nil
            }
        } onCancel: {
            activeTask.withLock { $0?.cancel() }
        }
        if again, !Task.isCancelled {
            startSync()
        }
    }

    private func activeTaskValue() async {
        await task?.value
    }

    /// Waits for any queued rule changes and the sync that's running, if any.
    func finish() async {
        await mutationTask?.value
        await task?.value
    }

    /// Stops the sync that's running, as when iOS ends a background sync. The songs downloaded
    /// so far stay, and the next sync carries on.
    public func stop() {
        again = false
        task?.cancel()
    }

    private static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private func runOnce(using externalSession: RemoteSession? = nil) async {
        let syncSession = externalSession ?? session
        let syncing = syncSession.syncing
        guard syncing.available else { return }
        guard networkAllows(settings.downloadNetwork) else {
            status.networkNotAllowed = true
            return
        }
        guard let store else {
            status.unavailable = true
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Self.excludeFromBackup(folder)
        } catch {
            Self.logger.error("Failed to create sync folder: \(error.localizedDescription, privacy: .public)")
            status.unavailable = true
            return
        }

        let activeManifests: SyncManifests
        var messageObserver: UUID?
        var statusObserver: UUID?
        if let externalSession {
            // Isolate background manifest waiters from self.manifests (wired to the foreground
            // session) and detach the temporary observers once the external sync finishes.
            let scoped = SyncManifests()
            activeManifests = scoped
            messageObserver = externalSession.addObserver { message in
                scoped.handle(message)
            }
            statusObserver = externalSession.addStatusObserver { status in
                switch status {
                case .disconnected, .suspended, .reconnecting:
                    scoped.failAll(SyncConnectionError.notConnected)
                case .connecting, .downloadingData, .connected:
                    break
                }
            }
        } else {
            activeManifests = manifests
        }
        defer {
            if let messageObserver { syncSession.removeObserver(messageObserver) }
            if let statusObserver { syncSession.removeStatusObserver(statusObserver) }
        }

        status.running = true
        status.unavailable = false
        status.networkNotAllowed = false
        let engine = SyncEngine(
            store: store, folder: folder, supportedFormats: Renderer.formats,
            progress: { [weak self] ruleID, now in await self?.show(now, for: ruleID) })
        let connection = ClementineSyncConnection(
            serverID: syncing.serverID, manifests: activeManifests,
            send: { [weak syncSession] in syncSession?.send($0) },
            server: { [weak syncSession] in syncSession?.connectedEndpoint ?? syncSession?.endpoint },
            timeout: timeout)
        defer { connection.invalidate() }
        do {
            status.results = try await engine.sync(connection).rules
        } catch is CancellationError {
            // Stopped: what finished stays, and the next sync carries on.
        } catch {
            // The store failing, say: tried again next time.
            Self.logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            status.unavailable = true
        }
        status.running = false
        progress = [:]
        await readKept()
    }

    private func show(_ now: SyncProgress, for ruleID: Int64) {
        progress[ruleID] = now
        if let index = kept.firstIndex(where: { $0.id == ruleID }) {
            kept[index].downloading = now
        }
    }
}
