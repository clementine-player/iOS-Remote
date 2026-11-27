import Foundation
import Network
import Synchronization

public enum ChannelError: Error, Sendable {
    /// Couldn't connect in time, or at all.
    case couldNotConnect
    /// iOS refused the local network permission, which connecting to this address needs.
    case localNetworkDenied
    /// The other side closed the connection, or it was cancelled.
    case closed
    /// Timed out waiting for a message.
    case timedOut
}

/// A TCP connection to Clementine carrying framed messages.
public final class MessageChannel: Sendable {
    public let endpoint: Endpoint

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.clementine-player.remote.channel")
    private let counters = Mutex((sent: 0, received: 0))
    private let connectedEndpoint = Mutex<Endpoint?>(nil)
    /// Whether its bytes count towards the app's [Traffic]: not for the Clementine end in tests.
    private let countsTraffic: Bool

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
        let port = NWEndpoint.Port(rawValue: endpoint.port) ?? NWEndpoint.Port(rawValue: RemoteProtocol.defaultPort)!
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        countsTraffic = true
    }

    /// A channel on a connection accepted by a listener (in tests), started straight away.
    init(accepted connection: NWConnection) {
        endpoint = Endpoint(host: "client")
        self.connection = connection
        countsTraffic = false
        connection.start(queue: queue)
    }

    /// Bytes sent and received so far, framing included.
    public var byteCounts: (sent: Int, received: Int) {
        counters.withLock { $0 }
    }

    /// The literal IP endpoint the underlying socket actually connected to, once ready.
    public var remoteEndpoint: Endpoint? {
        connectedEndpoint.withLock { $0 }
    }

    /// Connects, giving up after [timeout].
    public func open(timeout: Duration = .seconds(3)) async throws {
        try Task.checkCancellation()
        // NWConnection may never emit .cancelled if cancelled before start() or after clearing
        // stateUpdateHandler, and onCancel can race with storing the continuation.
        // ContinuationWaiter ensures exactly-once resumption across timeout, cancel, and state.
        let waiter = ContinuationWaiter<Void>()
        let finish: @Sendable (Result<Void, Error>) -> Void = { [connection] result in
            guard let continuation = waiter.finish() else { return }
            connection.stateUpdateHandler = nil
            switch result {
            case .success:
                if let resolved = Self.resolvedEndpoint(
                    from: connection.currentPath?.remoteEndpoint, fallbackPort: self.endpoint.port) {
                    self.connectedEndpoint.withLock { $0 = resolved }
                }
                continuation.resume()
            case .failure(let error):
                connection.cancel()
                continuation.resume(throwing: error)
            }
        }
        waiter.setTimer(Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            finish(.failure(ChannelError.couldNotConnect))
        })

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard waiter.store(continuation) else {
                    connection.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready:
                        finish(.success(()))
                    case .failed, .cancelled:
                        finish(.failure(ChannelError.couldNotConnect))
                    case .waiting:
                        // Refused or unreachable: Network would keep retrying.
                        let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                        finish(.failure(denied ? ChannelError.localNetworkDenied : ChannelError.couldNotConnect))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            if let continuation = waiter.cancel() {
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(throwing: CancellationError())
            } else {
                connection.cancel()
            }
        }
    }

    public func send(_ message: RemoteMessage, final: Bool = false) async throws {
        try Task.checkCancellation()
        let data = try Framing.encode(message)
        // Use ContinuationWaiter so task cancellation cancels the socket and resumes immediately
        // without waiting on or racing NWConnection's completion callback.
        let waiter = ContinuationWaiter<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard waiter.store(continuation) else {
                    connection.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Callers closing short-lived connections pass final=true so NWConnection sends a
                // clean TCP FIN after the disconnect frame.
                connection.send(
                    content: data,
                    contentContext: final ? .finalMessage : .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        guard let continuation = waiter.finish() else { return }
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                )
            }
        } onCancel: {
            if let continuation = waiter.cancel() {
                connection.cancel()
                continuation.resume(throwing: CancellationError())
            } else {
                connection.cancel()
            }
        }
        counters.withLock { $0.sent += data.count }
        if countsTraffic {
            Traffic.add(sent: data.count)
        }
    }

    /// Waits for the next message. Throws [ProtocolError] for bad data, and [ChannelError.closed],
    /// [ChannelError.timedOut], or a network error when the connection ends or times out.
    public func receive(timeout: Duration? = nil) async throws -> RemoteMessage {
        let header = try await read(4, timeout: timeout)
        let length = try Framing.length(ofHeader: header)
        let body = try await read(length, timeout: timeout)
        counters.withLock { $0.received += 4 + length }
        if countsTraffic {
            Traffic.add(received: 4 + length)
        }
        return try Framing.decode(body)
    }

    /// Closes the connection; waiting receives and sends fail.
    public func cancel() {
        connection.cancel()
    }

    private func read(_ count: Int, timeout: Duration? = nil) async throws -> Data {
        try Task.checkCancellation()
        if count == 0 {
            return Data()
        }
        let waiter = ContinuationWaiter<Data>()
        if let timeout {
            waiter.setTimer(Task { [connection] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                // Claim the waiter first so the caller receives .timedOut rather than .closed
                // when cancelling connection triggers the receive callback.
                guard let continuation = waiter.finish() else { return }
                connection.cancel()
                continuation.resume(throwing: ChannelError.timedOut)
            })
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard waiter.store(continuation) else {
                    connection.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    guard let continuation = waiter.finish() else { return }
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
            if let continuation = waiter.cancel() {
                connection.cancel()
                continuation.resume(throwing: CancellationError())
            } else {
                connection.cancel()
            }
        }
    }

    // MediaHttpServer authorizes /s/, /d/, and /a/ requests by comparing peer IP against the
    // protobuf socket. Extracting the literal IP prevents dual-stack Happy Eyeballs from picking
    // a different address family for HTTP; IPv4-mapped IPv6 addresses are unwrapped to plain IPv4.
    static func resolvedEndpoint(from endpoint: NWEndpoint?, fallbackPort: UInt16) -> Endpoint? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let portValue = port.rawValue == 0 ? fallbackPort : port.rawValue
        switch host {
        case .ipv4(let address):
            return Endpoint(host: formatIPv4(address), port: portValue)
        case .ipv6(let address):
            if let ipv4 = address.asIPv4 {
                return Endpoint(host: formatIPv4(ipv4), port: portValue)
            }
            return Endpoint(host: formatIPv6(address), port: portValue)
        case .name(let name, _):
            return Endpoint(host: name, port: portValue)
        @unknown default:
            return nil
        }
    }

    private static func formatIPv4(_ address: IPv4Address) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return address.rawValue.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  inet_ntop(AF_INET, base, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return address.debugDescription
            }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    private static func formatIPv6(_ address: IPv6Address) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let baseString = address.rawValue.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  inet_ntop(AF_INET6, base, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return address.debugDescription
            }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        // Link-local IPv6 addresses need their %interface zone to connect on the right interface.
        if let interface = address.interface, !baseString.contains("%") {
            return "\(baseString)%\(interface.name)"
        }
        return baseString
    }
}

/// Ensures a `CheckedContinuation` is resumed at most once across completion, timeout, and
/// task cancellation, even when cancellation fires before the continuation is stored.
private final class ContinuationWaiter<Value: Sendable>: Sendable {
    private enum State {
        case initial
        case waiting(CheckedContinuation<Value, Error>)
        case cancelled
        case finished
    }

    private struct Storage {
        var state: State = .initial
        var timer: Task<Void, Never>?
    }

    private let storage = Mutex(Storage())

    func setTimer(_ task: Task<Void, Never>) {
        let cancelImmediately = storage.withLock { storage -> Bool in
            switch storage.state {
            case .initial, .waiting:
                storage.timer = task
                return false
            case .cancelled, .finished:
                return true
            }
        }
        if cancelImmediately {
            task.cancel()
        }
    }

    func store(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let (stored, timer) = storage.withLock { storage -> (Bool, Task<Void, Never>?) in
            switch storage.state {
            case .initial:
                storage.state = .waiting(continuation)
                return (true, nil)
            case .cancelled, .finished, .waiting:
                storage.state = .finished
                let timer = storage.timer
                storage.timer = nil
                return (false, timer)
            }
        }
        timer?.cancel()
        return stored
    }

    func finish() -> CheckedContinuation<Value, Error>? {
        let (continuation, timer) = storage.withLock { storage -> (CheckedContinuation<Value, Error>?, Task<Void, Never>?) in
            let timer = storage.timer
            storage.timer = nil
            switch storage.state {
            case .waiting(let continuation):
                storage.state = .finished
                return (continuation, timer)
            case .initial, .cancelled, .finished:
                storage.state = .finished
                return (nil, timer)
            }
        }
        timer?.cancel()
        return continuation
    }

    func cancel() -> CheckedContinuation<Value, Error>? {
        let (continuation, timer) = storage.withLock { storage -> (CheckedContinuation<Value, Error>?, Task<Void, Never>?) in
            let timer = storage.timer
            storage.timer = nil
            switch storage.state {
            case .initial:
                // Record early cancellation before store() runs so store() rejects the continuation.
                storage.state = .cancelled
                return (nil, timer)
            case .waiting(let continuation):
                storage.state = .finished
                return (continuation, timer)
            case .cancelled, .finished:
                return (nil, timer)
            }
        }
        timer?.cancel()
        return continuation
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
