import Foundation
import Synchronization

/// Clementine's answers to REQUEST_SYNC_MANIFEST, handed to whoever asked for each source.
@MainActor
public final class SyncManifests {
    private var waiting: [UUID: (sourceID: String, continuation: CheckedContinuation<Pb_Remote_ResponseSyncManifest, any Error>)] = [:]

    public init() {}

    /// Hands on a SYNC_MANIFEST from Clementine.
    public func handle(_ message: RemoteMessage) {
        guard message.type == .syncManifest else { return }
        let manifest = message.responseSyncManifest
        for (id, waiter) in waiting where waiter.sourceID == manifest.sourceID {
            waiting[id] = nil
            waiter.continuation.resume(returning: manifest)
        }
    }

    /// Fails every pending manifest request, such as when the session drops or suspends.
    public func failAll(_ error: any Error = SyncConnectionError.notConnected) {
        let pending = waiting
        waiting.removeAll()
        for waiter in pending.values {
            waiter.continuation.resume(throwing: error)
        }
    }

    /// Sends [request] with [send], and waits for Clementine's answer for the same source: at
    /// most [timeout], after which it throws.
    func ask(
        _ request: Pb_Remote_RequestSyncManifest, send: @MainActor (RemoteMessage) -> Void, timeout: Duration
    ) async throws -> Pb_Remote_ResponseSyncManifest {
        try Task.checkCancellation()
        let id = UUID()
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.fail(id, SyncConnectionError.noAnswer(request.sourceID))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // If cancelled before storing, onCancel's @MainActor Task won't find waiting[id];
                // resume right away instead of inserting a leaked continuation.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Listening before asking, so the answer can't come first.
                waiting[id] = (request.sourceID, continuation)
                send(RemoteMessage(.requestSyncManifest) { $0.requestSyncManifest = request })
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.fail(id, CancellationError())
            }
        }
    }

    private func fail(_ id: UUID, _ error: any Error) {
        waiting.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }
}

public enum SyncConnectionError: Error, Equatable, LocalizedError {
    /// Clementine didn't answer for this source in time.
    case noAnswer(String)
    /// Not connected to Clementine, so there's nowhere to fetch songs from.
    case notConnected
    /// Clementine's 206 Partial Content response had a Content-Range at an unexpected offset.
    case rangeMismatch
    /// Clementine's HTTP server answered with this status.
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case .noAnswer(let sourceID): "Clementine didn't answer for \(sourceID)"
        case .notConnected: "Not connected"
        case .rangeMismatch: "Clementine sent an unexpected Content-Range"
        case .status(let code): "Clementine answered \(code)"
        }
    }
}

private final class DownloadTransfer: @unchecked Sendable {
    let destination: URL
    let etagURL: URL
    var expectedOffset: Int64
    var continuation: CheckedContinuation<Int, any Error>?
    var file: FileHandle?
    var statusCode = 0
    var receivedBytes = 0
    var writeError: (any Error)?
    private let cancelled = Mutex(false)

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func markCancelled() {
        cancelled.withLock { $0 = true }
    }

    init(destination: URL, etagURL: URL, expectedOffset: Int64) {
        self.destination = destination
        self.etagURL = etagURL
        self.expectedOffset = expectedOffset
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let transfers = Mutex<[Int: DownloadTransfer]>([:])

    func register(_ transfer: DownloadTransfer, for taskIdentifier: Int) {
        transfers.withLock { $0[taskIdentifier] = transfer }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let transfer = transfers.withLock({ $0[dataTask.taskIdentifier] }) else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        transfer.statusCode = status
        let etag = http?.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if status == 206, transfer.expectedOffset > 0 {
            // Verify Content-Range starts at expectedOffset before appending; a mismatched 206
            // (or an unexpected 206 when no Range was sent) must fail instead of corrupting.
            let contentRange = http?.value(forHTTPHeaderField: "Content-Range")?.lowercased() ?? ""
            guard contentRange.hasPrefix("bytes \(transfer.expectedOffset)-") else {
                transfer.writeError = SyncConnectionError.rangeMismatch
                completionHandler(.cancel)
                return
            }
            do {
                let handle = try FileHandle(forWritingTo: transfer.destination)
                try handle.seekToEnd()
                transfer.file = handle
                Self.saveETag(etag, to: transfer.etagURL)
                completionHandler(.allow)
            } catch {
                transfer.writeError = error
                completionHandler(.cancel)
            }
            return
        }

        if status == 200 {
            do {
                try FileManager.default.createDirectory(
                    at: transfer.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: transfer.destination)
                guard FileManager.default.createFile(atPath: transfer.destination.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                transfer.file = try FileHandle(forWritingTo: transfer.destination)
                Self.saveETag(etag, to: transfer.etagURL)
                completionHandler(.allow)
            } catch {
                transfer.writeError = error
                completionHandler(.cancel)
            }
            return
        }

        transfer.writeError = SyncConnectionError.status(status)
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfers.withLock({ $0[dataTask.taskIdentifier] }) else { return }
        do {
            try transfer.file?.write(contentsOf: data)
            transfer.receivedBytes += data.count
        } catch {
            transfer.writeError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let transfer = transfers.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? transfer.file?.close()
        transfer.file = nil
        if transfer.receivedBytes > 0 {
            Traffic.add(received: transfer.receivedBytes)
        }
        guard let continuation = transfer.continuation else { return }
        transfer.continuation = nil

        if let writeError = transfer.writeError {
            continuation.resume(throwing: writeError)
        } else if transfer.statusCode != 0, transfer.statusCode != 200, transfer.statusCode != 206 {
            continuation.resume(throwing: SyncConnectionError.status(transfer.statusCode))
        } else if let error {
            // Distinguish user/task cancellation from delegate-triggered dataTask.cancel()
            // (e.g. writeError or bad HTTP status) so real sync errors surface accurately.
            if transfer.isCancelled, (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
        } else {
            continuation.resume(returning: transfer.statusCode)
        }
    }

    private static func saveETag(_ etag: String, to url: URL) {
        if etag.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? Data(etag.utf8).write(to: url, options: .atomic)
        }
    }
}

// URLSession retains its delegate strongly until invalidated; wrapping it in SessionBox ensures
// invalidateAndCancel() runs when the connection finishes or deallocates.
private final class SessionBox: Sendable {
    let session: URLSession
    let delegate: DownloadDelegate

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let delegate = DownloadDelegate()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    deinit {
        session.invalidateAndCancel()
    }
}

/// The connected Clementine, for [SyncEngine]: manifests are asked for over the session's
/// connection ([send], answered through [manifests]), and songs are fetched from its HTTP server,
/// on the same address and port ([server]), as the renderer does.
public struct ClementineSyncConnection: SyncConnection {
    /// Resolving a big artist or playlist takes Clementine a moment.
    public static let manifestTimeout = Duration.seconds(60)

    public let serverID: String
    private let manifests: SyncManifests
    private let send: @MainActor @Sendable (RemoteMessage) -> Void
    private let server: @MainActor @Sendable () -> Endpoint?
    private let timeout: Duration
    private let box = SessionBox()

    public init(
        serverID: String, manifests: SyncManifests, send: @escaping @MainActor @Sendable (RemoteMessage) -> Void,
        server: @escaping @MainActor @Sendable () -> Endpoint?, timeout: Duration = Self.manifestTimeout
    ) {
        self.serverID = serverID
        self.manifests = manifests
        self.send = send
        self.server = server
        self.timeout = timeout
    }

    public func invalidate() {
        box.invalidate()
    }

    public func manifest(_ request: Pb_Remote_RequestSyncManifest) async throws -> Pb_Remote_ResponseSyncManifest {
        try await manifests.ask(request, send: send, timeout: timeout)
    }

    public func download(_ path: String, to file: URL) async throws {
        let server = server
        guard let url = await MainActor.run(body: { Renderer.resolve(path, on: server()) }) else {
            throw SyncConnectionError.notConnected
        }
        let etagURL = file.appendingPathExtension("etag")
        do {
            try await downloadOnce(url: url, to: file, etagURL: etagURL, allowResume: true)
            try? FileManager.default.removeItem(at: etagURL)
        } catch SyncConnectionError.status(416), SyncConnectionError.rangeMismatch {
            // Partial offset or ETag is stale; discard the partial file and retry from byte 0.
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: etagURL)
            try await downloadOnce(url: url, to: file, etagURL: etagURL, allowResume: false)
            try? FileManager.default.removeItem(at: etagURL)
        }
    }

    private func downloadOnce(url: URL, to file: URL, etagURL: URL, allowResume: Bool) async throws {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        var offset: Int64 = 0
        // Only send Range when a matching non-empty ETag was saved so resumed bytes are
        // guaranteed to belong to the same version of the track.
        if allowResume,
           let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value,
           size > 0,
           let etagData = try? Data(contentsOf: etagURL),
           let etag = String(data: etagData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !etag.isEmpty {
            offset = size
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        }

        let transfer = DownloadTransfer(destination: file, etagURL: etagURL, expectedOffset: offset)
        let task = box.session.dataTask(with: request)
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
                transfer.continuation = continuation
                box.delegate.register(transfer, for: task.taskIdentifier)
                if Task.isCancelled {
                    transfer.markCancelled()
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            transfer.markCancelled()
            task.cancel()
        }
    }
}
