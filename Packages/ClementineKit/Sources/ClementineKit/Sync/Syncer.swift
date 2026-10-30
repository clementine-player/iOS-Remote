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

/// Syncs the rules for the connected Clementine while the app is connected to it: each time it
/// connects, and when asked ([syncNow]), such as after a rule is made or removed. Background sync
/// comes later.
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
    /// The rules and synced songs; nil if it couldn't be opened.
    public let store: SyncStore?
    /// The synced songs' folder.
    public let folder: URL
    @ObservationIgnored private let session: RemoteSession
    @ObservationIgnored private let manifests = SyncManifests()
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var again = false

    public init(
        session: RemoteSession, store: SyncStore?, folder: URL,
        timeout: Duration = ClementineSyncConnection.manifestTimeout
    ) {
        self.session = session
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
        if message.type == .info, session.syncing.available {
            syncNow()
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
    }
}
