import Foundation
import Observation

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

    public var id: Int64 { rule.id }
}

/// Syncs the rules for the connected Clementine while the app is connected to it: each time it
/// connects, and when asked ([syncNow]), such as after a rule is made ([keep]) or removed
/// ([remove]). Background sync comes later.
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
    }

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
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var again = false

    public init(
        session: RemoteSession, store: SyncStore?, folder: URL, settings: Settings = Settings(),
        timeout: Duration = ClementineSyncConnection.manifestTimeout
    ) {
        self.session = session
        self.settings = settings
        self.store = store
        self.folder = folder
        self.timeout = timeout
        session.addObserver { [weak self] message in
            self?.handle(message)
        }
    }

    private func handle(_ message: RemoteMessage) {
        manifests.handle(message)
        // Clementine says what it can do each time the app connects.
        guard message.type == .info else { return }
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
        guard let store, !serverID.isEmpty, let rules = try? await store.rules(serverID: serverID) else { return }
        var kept: [KeptRule] = []
        for rule in rules {
            let songs = (try? await store.ruleItems(ruleID: rule.id)) ?? []
            kept.append(KeptRule(
                rule: rule, songs: songs.count, bytes: songs.reduce(0) { $0 + $1.sizeBytes },
                result: status.results[rule.id]))
        }
        self.kept = kept
    }

    /// Keeps [rules] on the phone, and syncs them. A rule for a source already kept is left as it
    /// is.
    public func keep(_ rules: [SyncRule]) {
        guard let store else { return }
        Task {
            for var rule in rules {
                let existing = (try? await store.rules(serverID: rule.serverID)) ?? []
                guard !existing.contains(where: { $0.sourceID == rule.sourceID }) else { continue }
                rule.position = (existing.map(\.position).max() ?? -1) + 1
                _ = try? await store.addRule(rule)
            }
            await readKept()
            syncNow()
        }
    }

    /// Stops keeping a rule, and deletes its songs that nothing else kept has.
    public func remove(_ ruleID: Int64) {
        guard let store else { return }
        Task {
            guard let rule = try? await store.rule(id: ruleID) else { return }
            try? await store.removeRule(id: ruleID)
            _ = try? await SyncEngine.removeUnwanted(store: store, serverID: rule.serverID, folder: folder)
            status.results[ruleID] = nil
            await readKept()
        }
    }

    /// Syncs now, or once more after the sync that's running.
    public func syncNow() {
        guard task == nil else {
            again = true
            return
        }
        task = Task {
            repeat {
                again = false
                await runOnce()
            } while again
            task = nil
        }
    }

    /// Waits for the sync that's running, if any.
    func finish() async {
        await task?.value
    }

    private func runOnce() async {
        let syncing = session.syncing
        guard syncing.available else { return }
        guard let store, (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else {
            status.unavailable = true
            return
        }
        status.running = true
        status.unavailable = false
        let engine = SyncEngine(store: store, folder: folder, supportedFormats: Renderer.formats)
        let connection = ClementineSyncConnection(
            serverID: syncing.serverID, manifests: manifests,
            send: { [weak session] in session?.send($0) }, server: { [weak session] in session?.endpoint },
            timeout: timeout)
        do {
            status.results = try await engine.sync(connection).rules
        } catch {
            // The store failing, say: tried again next time.
            status.unavailable = true
        }
        status.running = false
        await readKept()
    }
}
