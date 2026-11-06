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

    /// Syncs in the background with [session], the app's, through [syncer], and returns whether it
    /// synced. If the app is connected, its connection syncs. Otherwise it connects to the last
    /// Clementine that synced, or reconnects a session suspended in the background, syncs if the
    /// Clementine that answers is the one the rules are for, and disconnects again, unless
    /// [inBackground] says the user has opened the app meanwhile. Cancelling it, as when iOS ends
    /// the run, gives up waiting; [Syncer.stop] stops the sync itself.
    @discardableResult
    public static func run(
        session: RemoteSession, syncer: Syncer, settings: Settings, inBackground: () -> Bool = { true }
    ) async -> Bool {
        guard TestingFeatures.enabled, settings.backgroundSync else { return false }
        switch session.status {
        case .connected:
            syncer.syncNow()
            await syncer.finish()
            return true
        case .connecting, .downloadingData, .reconnecting:
            // Its connection syncs once Clementine says what it is.
            return false
        case .disconnected, .suspended:
            break
        }

        let serverID = settings.syncServerID
        guard !serverID.isEmpty, !settings.lastHost.isEmpty, let store = syncer.store,
              let rules = try? await store.rules(serverID: serverID), hasRulesToSync(rules)
        else { return false }

        syncer.onlyServerID = serverID
        defer { syncer.onlyServerID = nil }
        // The syncer starts syncing when Clementine says what it is, if it's the one. A suspended
        // session still has what the last Clementine said, so this waits for it to say it again.
        let heard = Heard()
        let observer = session.addObserver { message in
            if message.type == .info {
                heard.info = true
            }
        }
        defer { session.removeObserver(observer) }
        let wasSuspended = session.status == .suspended
        if wasSuspended {
            // Not offering the phone to play on: a Clementine could start playing on it unasked.
            session.resume(offeringRenderer: false)
        } else {
            session.connect(
                to: Endpoint(host: settings.lastHost, port: settings.port), authCode: settings.lastAuthCode,
                sendPlaylistSongs: false)
        }

        let deadline = ContinuousClock.now + connectTimeout
        while !heard.info, session.status != .disconnected, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let synced = heard.info && session.syncing.available && session.syncing.serverID == serverID
        if synced {
            await syncer.finish()
        }

        if inBackground() {
            if wasSuspended {
                session.suspend()
            } else {
                session.disconnect()
            }
        }
        return synced
    }
}

/// Whether Clementine has said what it is.
@MainActor
private final class Heard {
    var info = false
}
