import Foundation

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

    /// Sends [request] with [send], and waits for Clementine's answer for the same source: at
    /// most [timeout], after which it throws.
    func ask(
        _ request: Pb_Remote_RequestSyncManifest, send: @MainActor (RemoteMessage) -> Void, timeout: Duration
    ) async throws -> Pb_Remote_ResponseSyncManifest {
        let id = UUID()
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.fail(id, SyncConnectionError.noAnswer(request.sourceID))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
    /// Clementine's HTTP server answered with this status.
    case status(Int)

    public var errorDescription: String? {
        switch self {
        case .noAnswer(let sourceID): "Clementine didn't answer for \(sourceID)"
        case .notConnected: "Not connected"
        case .status(let code): "Clementine answered \(code)"
        }
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
    private let urls: URLSession

    public init(
        serverID: String, manifests: SyncManifests, send: @escaping @MainActor @Sendable (RemoteMessage) -> Void,
        server: @escaping @MainActor @Sendable () -> Endpoint?, timeout: Duration = Self.manifestTimeout
    ) {
        self.serverID = serverID
        self.manifests = manifests
        self.send = send
        self.server = server
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        urls = URLSession(configuration: configuration)
    }

    public func manifest(_ request: Pb_Remote_RequestSyncManifest) async throws -> Pb_Remote_ResponseSyncManifest {
        try await manifests.ask(request, send: send, timeout: timeout)
    }

    public func download(_ path: String, to file: URL) async throws {
        let server = server
        guard let url = await MainActor.run(body: { Renderer.resolve(path, on: server()) }) else {
            throw SyncConnectionError.notConnected
        }
        let (downloaded, response) = try await urls.download(from: url)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SyncConnectionError.status(status) }
        let size = (try? downloaded.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        Traffic.add(received: size)
        try FileManager.default.moveItem(at: downloaded, to: file)
    }
}
