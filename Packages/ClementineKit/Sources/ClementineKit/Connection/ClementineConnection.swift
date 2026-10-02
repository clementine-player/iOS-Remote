import Foundation

/// The app's connection to Clementine: connects, reports what Clementine sends, and keeps the
/// connection up, reconnecting when Clementine goes quiet or the network drops.
public actor ClementineConnection {

    public enum Event: Sendable {
        /// Connected, and the connect request sent.
        case connected
        /// A message from Clementine.
        case message(RemoteMessage)
        /// The connection was lost, and the app is trying to reconnect.
        case reconnecting
        /// Reconnected after [reconnecting].
        case reconnected
        /// The connection has ended, for good.
        case closed(CloseReason)
    }

    public enum CloseReason: Sendable, Equatable {
        /// The app disconnected.
        case requested
        /// Couldn't connect at all.
        case couldNotConnect
        /// iOS refused the local network permission, which connecting to this address needs.
        case localNetworkDenied
        /// Clementine closed the connection, for this reason if it gave one.
        case disconnected(DisconnectReason?)
        /// The connection was lost and couldn't be restored.
        case lost
        /// Clementine is too old.
        case oldProtocol
        /// Clementine sent something that isn't a message.
        case invalidData
    }

    public struct Configuration: Sendable {
        /// Clementine sends a keep-alive every 10 seconds; nothing for this long means it's gone.
        public var keepAliveTimeout: Duration = .seconds(25)
        public var connectTimeout: Duration = .seconds(3)
        public var maxReconnects = 5
        public var reconnectDelay: Duration = .seconds(1)

        public init() {}
    }

    public let endpoint: Endpoint
    public let authCode: Int32
    /// Offered when connecting, so Clementine can play on this device.
    public let renderer: RendererCapabilities?
    public nonisolated let events: AsyncStream<Event>

    private let configuration: Configuration
    private let eventsContinuation: AsyncStream<Event>.Continuation
    private var channel: MessageChannel?
    private var lastHeard = ContinuousClock.now
    /// Whether Clementine has sent anything on this connection yet.
    private var hasHeard = false
    /// Reconnections since Clementine last sent anything: one that accepts the connection and
    /// closes it straight away would otherwise be reconnected to forever.
    private var reconnectsUnheard = 0
    private var closed = false
    private var runTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Bytes of the channels closed already.
    private var earlierBytes = (sent: 0, received: 0)

    public init(
        endpoint: Endpoint, authCode: Int32, renderer: RendererCapabilities? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.endpoint = endpoint
        self.authCode = authCode
        self.renderer = renderer
        self.configuration = configuration
        (events, eventsContinuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// Connects. With [sendPlaylistSongs], Clementine sends the active playlist's songs too.
    public func start(sendPlaylistSongs: Bool = true) {
        guard runTask == nil, !closed else { return }
        runTask = Task { await run(sendPlaylistSongs: sendPlaylistSongs) }
    }

    /// Sends a command. If the connection has dropped, the message is lost, and the connection
    /// reconnects.
    public func send(_ message: RemoteMessage) async {
        guard let channel, !closed else { return }
        do {
            try await channel.send(message)
        } catch {
            // The read loop sees the connection fail and reconnects.
            channel.cancel()
        }
    }

    /// Says goodbye to Clementine and closes the connection.
    public func disconnect() async {
        guard !closed else { return }
        if let channel {
            try? await channel.send(RemoteMessage(.disconnect))
        }
        finish(.requested)
    }

    /// Bytes sent and received since connecting, across reconnections.
    public var byteCounts: (sent: Int, received: Int) {
        let current = channel?.byteCounts ?? (sent: 0, received: 0)
        return (earlierBytes.sent + current.sent, earlierBytes.received + current.received)
    }

    private func run(sendPlaylistSongs: Bool) async {
        var channel: MessageChannel
        do {
            channel = try await open(sendPlaylistSongs: sendPlaylistSongs)
        } catch ChannelError.localNetworkDenied {
            finish(.localNetworkDenied)
            return
        } catch {
            finish(.couldNotConnect)
            return
        }
        use(channel)
        eventsContinuation.yield(.connected)
        startWatchdog()

        while !closed {
            do {
                let message = try await channel.receive()
                lastHeard = .now
                hasHeard = true
                reconnectsUnheard = 0
                if message.type == .disconnect {
                    let response = message.responseDisconnect
                    finish(.disconnected(response.hasReasonDisconnect ? response.reasonDisconnect : nil))
                    return
                }
                if message.type != .keepAlive {
                    eventsContinuation.yield(.message(message))
                }
            } catch ProtocolError.oldProtocol {
                finish(.oldProtocol)
                return
            } catch ProtocolError.invalidData, ProtocolError.invalidLength {
                finish(.invalidData)
                return
            } catch {
                if closed {
                    return
                }
                if !hasHeard {
                    // Clementine closed the connection without a word: it won't take this one.
                    finish(.couldNotConnect)
                    return
                }
                reconnectsUnheard += 1
                guard reconnectsUnheard <= configuration.maxReconnects, let restored = await reconnect() else {
                    finish(.lost)
                    return
                }
                channel = restored
            }
        }
    }

    private func reconnect() async -> MessageChannel? {
        eventsContinuation.yield(.reconnecting)
        retire(channel)
        for attempt in 0..<configuration.maxReconnects {
            if attempt > 0 {
                try? await Task.sleep(for: configuration.reconnectDelay)
            }
            if closed {
                return nil
            }
            if let channel = try? await open(sendPlaylistSongs: false) {
                use(channel)
                eventsContinuation.yield(.reconnected)
                return channel
            }
        }
        return nil
    }

    private func open(sendPlaylistSongs: Bool) async throws -> MessageChannel {
        let channel = MessageChannel(endpoint: endpoint)
        do {
            try await channel.open(timeout: configuration.connectTimeout)
            try await channel.send(Messages.connect(
                authCode: authCode, sendPlaylistSongs: sendPlaylistSongs, downloader: false, renderer: renderer))
            return channel
        } catch {
            channel.cancel()
            throw error
        }
    }

    private func use(_ channel: MessageChannel) {
        self.channel = channel
        lastHeard = .now
    }

    private func retire(_ channel: MessageChannel?) {
        guard let channel else { return }
        channel.cancel()
        let bytes = channel.byteCounts
        earlierBytes.sent += bytes.sent
        earlierBytes.received += bytes.received
        if self.channel === channel {
            self.channel = nil
        }
    }

    /// Drops a connection Clementine has stopped talking on, so the read loop reconnects.
    private func startWatchdog() {
        watchdogTask = Task { [configuration] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if checkKeepAlive(timeout: configuration.keepAliveTimeout) {
                    return
                }
            }
        }
    }

    /// Returns true once closed.
    private func checkKeepAlive(timeout: Duration) -> Bool {
        if closed {
            return true
        }
        if ContinuousClock.now - lastHeard > timeout, let channel {
            lastHeard = .now
            channel.cancel()
        }
        return false
    }

    private func finish(_ reason: CloseReason) {
        guard !closed else { return }
        closed = true
        watchdogTask?.cancel()
        retire(channel)
        eventsContinuation.yield(.closed(reason))
        eventsContinuation.finish()
    }
}
