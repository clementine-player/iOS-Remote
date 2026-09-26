import Foundation
import Network
import Synchronization

public enum ChannelError: Error, Sendable {
    /// Couldn't connect in time, or at all.
    case couldNotConnect
    /// The other side closed the connection, or it was cancelled.
    case closed
}

/// A TCP connection to Clementine carrying framed messages.
public final class MessageChannel: Sendable {
    public let endpoint: Endpoint

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.clementine-player.remote.channel")
    private let counters = Mutex((sent: 0, received: 0))

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
        let port = NWEndpoint.Port(rawValue: endpoint.port) ?? NWEndpoint.Port(rawValue: RemoteProtocol.defaultPort)!
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: NWParameters(tls: nil, tcp: tcp))
    }

    /// A channel on a connection accepted by a listener (in tests), started straight away.
    init(accepted connection: NWConnection) {
        endpoint = Endpoint(host: "client")
        self.connection = connection
        connection.start(queue: queue)
    }

    /// Bytes sent and received so far, framing included.
    public var byteCounts: (sent: Int, received: Int) {
        counters.withLock { $0 }
    }

    /// Connects, giving up after [timeout].
    public func open(timeout: Duration = .seconds(3)) async throws {
        let once = Once()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resume: @Sendable (Error?) -> Void = { error in
                    guard once.claim() else { return }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        resume(nil)
                    case .failed, .cancelled:
                        resume(ChannelError.couldNotConnect)
                    case .waiting:
                        // Refused or unreachable: Network would keep retrying.
                        resume(ChannelError.couldNotConnect)
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [connection] in
                    if once.isUnclaimed {
                        connection.cancel()
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        connection.stateUpdateHandler = nil
    }

    public func send(_ message: RemoteMessage) async throws {
        let data = try Framing.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        counters.withLock { $0.sent += data.count }
    }

    /// Waits for the next message. Throws [ProtocolError] for bad data, and [ChannelError.closed] or
    /// a network error when the connection ends.
    public func receive() async throws -> RemoteMessage {
        let header = try await read(4)
        let length = try Framing.length(ofHeader: header)
        let body = try await read(length)
        counters.withLock { $0.received += 4 + length }
        return try Framing.decode(body)
    }

    /// Closes the connection; waiting receives and sends fail.
    public func cancel() {
        connection.cancel()
    }

    private func read(_ count: Int) async throws -> Data {
        if count == 0 {
            return Data()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, data.count == count {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: ChannelError.closed)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Lets exactly one caller through.
final class Once: Sendable {
    private let claimed = Mutex(false)

    /// True for the first caller only.
    func claim() -> Bool {
        claimed.withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }

    var isUnclaimed: Bool {
        claimed.withLock { !$0 }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
