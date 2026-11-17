import Foundation
import Testing
@testable import ClementineKit

/// Keeping crash reports until the user says whether to send them, and sending them to Sentry.
struct CrashReportTests {
    static let dsn = SentryDSN("https://abc123@o42.ingest.de.sentry.io/7")!

    static func store() -> CrashReportStore {
        CrashReportStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "CrashReportTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    static func event(_ id: String = UUID().uuidString.lowercased()) -> [String: Any] {
        ["event_id": id, "level": "fatal", "platform": "cocoa", "timestamp": 1_763_000_000.5]
    }

    @Test func readsTheDSN() throws {
        let dsn = try #require(SentryDSN("https://abc123@o42.ingest.de.sentry.io/7"))
        #expect(dsn.publicKey == "abc123")
        #expect(dsn.envelopeURL.absoluteString == "https://o42.ingest.de.sentry.io/api/7/envelope/")

        let served = try #require(SentryDSN("http://key@sentry.example.com:9000/sentry/12"))
        #expect(served.envelopeURL.absoluteString == "http://sentry.example.com:9000/sentry/api/12/envelope/")
    }

    @Test func turnsDownWhatIsNotADSN() {
        #expect(SentryDSN("") == nil)
        #expect(SentryDSN("https://o42.ingest.de.sentry.io/7") == nil)  // No key
        #expect(SentryDSN("https://abc@o42.ingest.de.sentry.io/") == nil)  // No project
        #expect(SentryDSN("ftp://abc@example.com/7") == nil)
    }

    @Test func keepsReportsUntilAsked() throws {
        let store = Self.store()
        defer { store.removeAll() }
        #expect(store.pendingReports.isEmpty)

        try store.keep(event: Self.event("0123abcd-0000-0000-0000-000000000000"))
        #expect(store.pendingReports.map(\.lastPathComponent) == ["0123abcd-0000-0000-0000-000000000000.json"])
        #expect(store.approvedReports.isEmpty)

        store.approvePending()
        #expect(store.pendingReports.isEmpty)
        #expect(store.approvedReports.count == 1)
    }

    @Test func forgetsReportsTheUserDoesNotSend() throws {
        let store = Self.store()
        defer { store.removeAll() }
        try store.keep(event: Self.event())
        store.discardPending()
        #expect(store.pendingReports.isEmpty)
        #expect(store.approvedReports.isEmpty)
    }

    @Test func keepsOnlyTheNewestReports() throws {
        let store = Self.store()
        defer { store.removeAll() }
        for _ in 0..<(CrashReportStore.limit + 3) {
            try store.keep(event: Self.event())
        }
        #expect(store.pendingReports.count == CrashReportStore.limit)
    }

    @Test func namesFilesSafely() throws {
        let store = Self.store()
        defer { store.removeAll() }
        try store.keep(event: ["event_id": "../../escape", "level": "fatal"])
        let report = try #require(store.pendingReports.first)
        #expect(report.deletingLastPathComponent().standardizedFileURL == store.pending.standardizedFileURL)
        #expect(!report.lastPathComponent.contains("escape"))
    }

    @Test func refusesWhatIsNotJSON() {
        let store = Self.store()
        defer { store.removeAll() }
        #expect(throws: CrashReportError.self) {
            try store.keep(event: ["event_id": "abc", "when": Date()])
        }
    }

    @Test func makesAnEnvelope() throws {
        let event = try JSONSerialization.data(withJSONObject: Self.event("feed"))
        let envelope = try #require(CrashReportUpload.envelope(
            event: event, dsn: Self.dsn, sentAt: Date(timeIntervalSince1970: 0)))
        let lines = envelope.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        #expect(lines.count == 4)
        let header = try #require(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        #expect(header["event_id"] as? String == "feed")
        #expect(header["dsn"] as? String == Self.dsn.string)
        #expect(header["sent_at"] as? String == "1970-01-01T00:00:00Z")
        let item = try #require(try JSONSerialization.jsonObject(with: Data(lines[1])) as? [String: Any])
        #expect(item["type"] as? String == "event")
        #expect(item["length"] as? Int == event.count)
        #expect(Data(lines[2]) == event)
        #expect(lines[3].isEmpty)
    }

    @Test func makesNoEnvelopeWithoutAnEventID() throws {
        let event = try JSONSerialization.data(withJSONObject: ["level": "fatal"])
        #expect(CrashReportUpload.envelope(event: event, dsn: Self.dsn) == nil)
    }

    @Test func postsTheEnvelopeToTheProject() {
        let request = CrashReportUpload.request(envelope: Data("x".utf8), dsn: Self.dsn)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.dsn.envelopeURL)
        #expect(request.value(forHTTPHeaderField: "X-Sentry-Auth")?.contains("sentry_key=abc123") == true)
        #expect(request.httpBody == Data("x".utf8))
    }

    @Test func keepsReportsSentryMightTakeLater() {
        #expect(CrashReportUpload.isFinished(status: 200))
        #expect(CrashReportUpload.isFinished(status: 400))
        #expect(CrashReportUpload.isFinished(status: 413))
        #expect(!CrashReportUpload.isFinished(status: 429))
        #expect(!CrashReportUpload.isFinished(status: 500))
        #expect(!CrashReportUpload.isFinished(status: 503))
    }
}
