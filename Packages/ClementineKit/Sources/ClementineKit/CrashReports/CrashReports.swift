import Foundation

/// Serializes uploads per report directory so concurrent triggers (e.g. launch plus user
/// approval) cannot upload the same report twice before it is deleted.
private actor CrashReportSendLock {
    static let shared = CrashReportSendLock()
    private var locked: Set<URL> = []
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func withLock(_ directory: URL, _ operation: @Sendable () async -> Void) async {
        let key = directory.standardizedFileURL
        if locked.contains(key) {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        } else {
            locked.insert(key)
        }
        defer {
            if var queue = waiters[key], !queue.isEmpty {
                let next = queue.removeFirst()
                waiters[key] = queue.isEmpty ? nil : queue
                next.resume()
            } else {
                locked.remove(key)
            }
        }
        await operation()
    }
}

/// Crash reports, kept on the phone until the user says whether to send them.
///
/// The app's crash reporter (Sentry's SDK, in the app) writes a report when the app crashes, and
/// turns it into an event the next time the app starts. Rather than let the SDK send it, the app
/// keeps the event here, as JSON, and asks. A report the user agrees to send moves to `approved`
/// and is sent from there, straight away, or the next time the app starts if it couldn't be; one
/// they don't is deleted. The desktop Clementine does the same.
public struct CrashReportStore: Sendable {
    /// Reports waiting for the user to say whether to send them.
    public let pending: URL
    /// Reports the user agreed to send, waiting to be sent.
    public let approved: URL

    /// The most reports kept waiting for an answer: an app that crashes as it starts makes a new
    /// one each time it's opened.
    public static let limit = 5

    public init(directory: URL) {
        pending = directory.appending(path: "pending", directoryHint: .isDirectory)
        approved = directory.appending(path: "approved", directoryHint: .isDirectory)
    }

    /// In the app's Application Support folder, which isn't in the Files app.
    public static var standard: CrashReportStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CrashReportStore(directory: support.appending(path: "CrashReports", directoryHint: .isDirectory))
    }

    /// Keeps a report to ask about: an event, as Sentry's SDK serializes it. Only the newest
    /// `limit` are kept.
    public func keep(event: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(event) else { throw CrashReportError.notJSON }
        let data = try JSONSerialization.data(withJSONObject: event)
        let id = (event["event_id"] as? String).flatMap(Self.safeName) ?? UUID().uuidString
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try data.write(to: pending.appending(path: "\(id).json"), options: .atomic)
        for old in reports(in: pending).dropLast(Self.limit) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// The reports waiting for an answer, oldest first.
    public var pendingReports: [URL] { reports(in: pending) }

    /// The reports the user agreed to send that haven't been sent yet, oldest first.
    public var approvedReports: [URL] { reports(in: approved) }

    /// The user agreed to send the reports waiting for an answer.
    public func approvePending() {
        try? FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
        for report in pendingReports {
            let destination = approved.appending(path: report.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: report, to: destination)
        }
    }

    /// The user doesn't want to send the reports waiting for an answer.
    public func discardPending() {
        try? FileManager.default.removeItem(at: pending)
    }

    /// Deletes every report, sent or not: when the user turns crash reports off.
    public func removeAll() {
        try? FileManager.default.removeItem(at: pending)
        try? FileManager.default.removeItem(at: approved)
    }

    /// Sends the reports the user agreed to send. Each is deleted once Sentry has it, or once
    /// Sentry has turned it down for good; one that couldn't be sent, offline say, is kept to try
    /// again the next time the app starts.
    public func sendApproved(to dsn: SentryDSN, session: URLSession = .shared) async {
        await CrashReportSendLock.shared.withLock(approved) {
            for report in approvedReports {
                let event: Data
                do {
                    event = try Data(contentsOf: report)
                } catch {
                    // Keep the report across transient read errors so it can retry later.
                    continue
                }
                guard let envelope = CrashReportUpload.envelope(event: event, dsn: dsn) else {
                    // Permanently corrupt/unparseable event: delete so it can't block future uploads.
                    try? FileManager.default.removeItem(at: report)
                    continue
                }
                guard let (_, response) = try? await session.data(for: CrashReportUpload.request(envelope: envelope, dsn: dsn)),
                    let status = (response as? HTTPURLResponse)?.statusCode
                else {
                    continue
                }
                if CrashReportUpload.isFinished(status: status) {
                    try? FileManager.default.removeItem(at: report)
                }
            }
        }
    }

    private func reports(in directory: URL) -> [URL] {
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let reports: [(url: URL, created: Date)] = files
            .filter { $0.pathExtension == "json" }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                return (url, created ?? .distantPast)
            }
        return reports
            .sorted { (a: (url: URL, created: Date), b: (url: URL, created: Date)) -> Bool in
                if a.created != b.created {
                    return a.created < b.created
                }
                return a.url.lastPathComponent < b.url.lastPathComponent
            }
            .map { $0.url }
    }

    /// An event ID as a file name: hex digits and dashes only.
    private static func safeName(_ id: String) -> String? {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return !id.isEmpty && id.unicodeScalars.allSatisfy(allowed.contains) ? id : nil
    }
}

public enum CrashReportError: Error {
    /// Sentry's SDK gave an event that can't be written as JSON.
    case notJSON
}

/// A Sentry project's DSN, such as `https://key@o1.ingest.de.sentry.io/2`: where its events go, and
/// the public key that lets them in.
public struct SentryDSN: Sendable, Equatable {
    /// The DSN as it was written.
    public let string: String
    public let publicKey: String
    /// Where the project takes envelopes of events.
    public let envelopeURL: URL

    public init?(_ string: String) {
        guard let components = URLComponents(string: string),
            let scheme = components.scheme, ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty,
            let key = components.user, !key.isEmpty
        else {
            return nil
        }
        // The project's ID is the last part of the path; anything before it is where Sentry is
        // served from, for one that isn't at the root of its host.
        var path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let project = path.popLast(), !project.isEmpty else { return nil }
        var url = URLComponents()
        url.scheme = scheme
        url.host = host
        url.port = components.port
        url.path = "/" + (path + ["api", project, "envelope"]).joined(separator: "/") + "/"
        guard let envelopeURL = url.url else { return nil }
        self.string = string
        self.publicKey = key
        self.envelopeURL = envelopeURL
    }
}

/// Sends a kept event to Sentry, as Sentry's SDKs do: in an envelope, posted to the project.
public enum CrashReportUpload {
    /// What identifies the sender to Sentry.
    static let client = "clementine-remote-ios"

    /// An envelope holding the event: a header, then the event as its only item.
    public static func envelope(event: Data, dsn: SentryDSN, sentAt: Date = .now) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: event),
            let fields = object as? [String: Any],
            let id = fields["event_id"] as? String
        else {
            return nil
        }
        let header: [String: Any] = [
            "event_id": id,
            "dsn": dsn.string,
            "sent_at": sentAt.formatted(.iso8601),
        ]
        let item: [String: Any] = ["type": "event", "length": event.count]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header, options: .sortedKeys),
            let itemData = try? JSONSerialization.data(withJSONObject: item, options: .sortedKeys)
        else {
            return nil
        }
        let newline = Data("\n".utf8)
        return headerData + newline + itemData + newline + event + newline
    }

    /// The request that sends an envelope to the project.
    public static func request(envelope: Data, dsn: SentryDSN) -> URLRequest {
        var request = URLRequest(url: dsn.envelopeURL)
        request.httpMethod = "POST"
        request.httpBody = envelope
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Sentry sentry_version=7, sentry_key=\(dsn.publicKey), sentry_client=\(client)",
            forHTTPHeaderField: "X-Sentry-Auth")
        return request
    }

    /// Whether a report is done with after Sentry answered with this status: it took it, or turned
    /// it down in a way that sending it again won't change. Not when it's limiting how often
    /// it's sent to (429), or failed itself (5xx).
    public static func isFinished(status: Int) -> Bool {
        switch status {
        case 200..<300: true
        case 429: false
        case 400..<500: true
        default: false
        }
    }
}
