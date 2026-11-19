import ClementineKit
import Foundation
import Sentry

/// Asks to send a crash report after the app crashes, as the desktop Clementine does.
///
/// Sentry's SDK catches the crash and, the next time the app starts, turns its report into an
/// event. The app never lets the SDK send anything itself: it keeps crash events in a
/// CrashReportStore, drops everything else, and asks the user. Only the reports they agree to
/// send are sent, by CrashReportStore.
///
/// It's on in builds made with a DSN (`SENTRY_DSN`), which App Store and TestFlight builds are
/// (`scripts/archive.sh`), unless the user turns it off in Settings.
@MainActor
@Observable
final class CrashReporting {
    static weak var shared: CrashReporting?

    /// The Sentry project crash reports go to, if this build sends them anywhere.
    static let dsn = (Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String).flatMap(SentryDSN.init)

    /// Whether this build can send crash reports, for Settings to offer to turn them off.
    static var isAvailable: Bool { dsn != nil }

    /// Whether there are reports to ask the user about.
    var isAsking = false

    @ObservationIgnored private let store = CrashReportStore.standard

    init() {
        Self.shared = self
    }

    /// Starts catching crashes, and sends any reports the user agreed to send but that couldn't be
    /// sent then. Called as the app starts.
    func start() {
        guard let dsn = Self.dsn else { return }
        guard UserDefaults.standard.object(forKey: SettingKey.crashReports) as? Bool ?? true else {
            store.removeAll()
            return
        }
        SentrySDK.start(options: Self.options(dsn: dsn, store: store))
        reportsChanged()
        send(to: dsn)
    }

    /// The user agreed to send the reports.
    func send() {
        store.approvePending()
        isAsking = false
        if let dsn = Self.dsn {
            send(to: dsn)
        }
    }

    /// The user doesn't want to send the reports.
    func discard() {
        store.discardPending()
        isAsking = false
    }

    /// Crashes the app, to try crash reports out. Only TestFlight and debug builds offer it, and
    /// it crashes under Xcode's debugger without a report.
    ///
    /// The report is tagged `crash_type:forced`, as the desktop Clementine tags crashes made with
    /// `--crash`, so it can be told apart from real crashes in Sentry. The SDK saves the scope with
    /// its report of the crash, so the tag is on the event it makes from it on the next start.
    func crash() {
        SentrySDK.configureScope { scope in
            scope.setTag(value: "forced", key: "crash_type")
        }
        SentrySDK.crash()
    }

    private func reportsChanged() {
        isAsking = !store.pendingReports.isEmpty
    }

    private func send(to dsn: SentryDSN) {
        let store = store
        Task.detached(priority: .utility) {
            await store.sendApproved(to: dsn)
        }
    }

    /// Sentry's options: crashes only, kept for the user to decide on. Nonisolated, so that the
    /// SDK can call `beforeSend` on its own threads.
    private nonisolated static func options(dsn: SentryDSN, store: CrashReportStore) -> Options {
        let options = Options()
        options.dsn = dsn.string
        options.environment = TestingFeatures.enabled ? "testflight" : "production"
        // Nothing but crashes: no sessions, performance, hangs that recovered, failed requests or
        // reports about the SDK itself.
        options.enableAutoSessionTracking = false
        options.enableAutoPerformanceTracing = false
        options.enableWatchdogTerminationTracking = false
        options.enableCaptureFailedRequests = false
        options.sendClientReports = false
        // Nor what the user did before it crashed, which can name their music: the screens,
        // buttons and requests (to their own Clementine, with its address) the SDK would keep.
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.sendDefaultPii = false
        options.beforeSend = { event in
            if event.level == .fatal {
                do {
                    try store.keep(event: event.serialize())
                    Task { @MainActor in
                        CrashReporting.shared?.reportsChanged()
                    }
                } catch {
                    NSLog("Couldn't keep a crash report: %@", "\(error)")
                }
            }
            // Sent, if the user agrees, by CrashReportStore: the SDK sends nothing.
            return nil
        }
        return options
    }
}
