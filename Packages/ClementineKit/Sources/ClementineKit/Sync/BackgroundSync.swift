import Foundation

/// Updates what's kept on the phone in the background, with Update kept music in the background
/// on. The app runs [run] from a background processing task about every 6 hours, which iOS starts
/// while the phone is on power, usually overnight. A run connects to the last Clementine that
/// synced, at its last address, syncs its rules and disconnects.
@MainActor
public enum BackgroundSync {
    /// How soon after one run the next may start.
    public static let interval: TimeInterval = 6 * 60 * 60
    /// How long a run waits for Clementine to say what it is.
    static let connectTimeout: Duration = .seconds(15)

    /// Whether a run may use a network that's [expensive], such as mobile data, and
    /// [constrained], in Low Data Mode: what [network], chosen under Download over, allows, but
    /// never in Low Data Mode, which asks apps to hold back work that can wait.
    public nonisolated static func allows(_ network: DownloadNetwork, expensive: Bool, constrained: Bool) -> Bool {
        !constrained && network.allows(expensive: expensive, constrained: constrained)
    }

    /// Whether any of [rules] would sync: those updated each time, and those yet to get their
    /// songs.
    static func hasRulesToSync(_ rules: [SyncRule]) -> Bool {
        rules.contains { $0.refreshPolicy != .never || $0.lastSynced == nil }
    }

    /// Syncs in the background using [syncer]: if [session] is already connected, it syncs over it;
    /// otherwise it opens a dedicated short-lived session to the last Clementine that synced (never
    /// mutating the app's suspended or disconnected session) and runs it sequentially through
    /// [syncer] so at most one sync accesses the store and folder at once.
    @discardableResult
    public static func run(
        session: RemoteSession, syncer: Syncer, settings: Settings, inBackground: () -> Bool = { true }
    ) async -> Bool {
        guard TestingFeatures.enabled, settings.backgroundSync else { return false }
        switch session.status {
        case .connected:
            // Cancelling BackgroundSync (e.g. BGProcessingTask expiration) must stop the active
            // sync itself, not just abandon waiting on syncer.finish().
            await withTaskCancellationHandler {
                syncer.syncNow()
                await syncer.finish()
            } onCancel: {
                Task { @MainActor in syncer.stop() }
            }
            return true
        case .connecting, .downloadingData, .reconnecting:
            // Its connection syncs once Clementine says what it is.
            return false
        case .disconnected, .suspended:
            break
        }

        let serverID = settings.syncServerID
        // Use the live session endpoint if known, falling back to the last connected server's
        // port (then settings.port) so servers on non-default ports still sync in the background.
        let endpoint = session.endpoint ?? Endpoint(host: settings.lastHost, port: settings.lastPort ?? settings.port)
        guard !serverID.isEmpty, !endpoint.host.isEmpty, let store = syncer.store,
              let rules = try? await store.rules(serverID: serverID), hasRulesToSync(rules)
        else { return false }

        // Use an isolated session so off-LAN background probes never wipe or alert on the
        // user's suspended foreground session.
        let backgroundSession = RemoteSession()
        defer { backgroundSession.disconnect() }

        let heard = Heard()
        let observer = backgroundSession.addObserver { message in
            if message.type == .info {
                heard.info = true
            }
        }
        defer { backgroundSession.removeObserver(observer) }

        backgroundSession.connect(to: endpoint, authCode: settings.lastAuthCode, sendPlaylistSongs: false)

        let deadline = ContinuousClock.now + connectTimeout
        while !heard.info, backgroundSession.status != .disconnected,
              ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard heard.info, backgroundSession.syncing.available,
              backgroundSession.syncing.serverID == serverID,
              !Task.isCancelled
        else { return false }
        // If the user brought the app back to the foreground while connecting, let the foreground
        // connection handle syncing unless it's still disconnected/suspended.
        guard inBackground() || session.status == .disconnected || session.status == .suspended else {
            return false
        }
        syncer.onlyServerID = serverID
        defer { syncer.onlyServerID = nil }
        await syncer.runExternalSync(using: backgroundSession)
        return true
    }
}

/// Whether Clementine has said what it is.
@MainActor
private final class Heard {
    var info = false
}
