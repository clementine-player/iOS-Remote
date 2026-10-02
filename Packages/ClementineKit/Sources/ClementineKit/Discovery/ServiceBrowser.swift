import dnssd
import Foundation
import Network

/// A Clementine found on the network.
public struct DiscoveredServer: Sendable, Hashable, Identifiable {
    /// The name Clementine announces, usually its computer's name.
    public var name: String
    /// Its IPv4 address.
    public var host: String
    public var port: UInt16

    public var id: String { name }

    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Finds the Clementines on the local network, which announce themselves as `_clementine._tcp`.
@MainActor
@Observable
public final class ServiceBrowser {
    public static let serviceType = "_clementine._tcp"

    /// The Clementines found so far, by name.
    public private(set) var servers: [DiscoveredServer] = []
    /// Whether iOS has refused the local network permission, so no Clementine can be found.
    /// Connecting to an address still works.
    public private(set) var isLocalNetworkDenied = false

    private var browser: NWBrowser?
    private var resolvers: [String: Resolver] = [:]
    private var restart: Task<Void, Never>?

    /// How long to wait before looking again after browsing fails, or resolving a Clementine.
    static let retryDelay = Duration.seconds(2)
    static let resolveTimeout = Duration.seconds(5)

    public init() {}

    /// Starts looking, from scratch: call it again when the app comes back to the foreground, as
    /// iOS may have stopped the search while the app was suspended.
    public func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.update(names: Set(names)) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error) where Self.isLocalNetworkDenied(error):
                // Looking again won't help until it's allowed in Settings, and the app looks again
                // when it comes back from there.
                Task { @MainActor in self?.denied(browser) }
            case .failed, .waiting:
                // Failed, or waiting for the network: look again shortly, as a browser doesn't
                // always recover by itself.
                Task { @MainActor in self?.retry(browser) }
            case .ready:
                Task { @MainActor in self?.ready(browser) }
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Whether [error] means iOS refused the local network permission.
    nonisolated static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        }
        return false
    }

    private func denied(_ browser: NWBrowser) {
        guard self.browser === browser else { return }
        isLocalNetworkDenied = true
    }

    /// A browser is ready just before it's refused the permission, so it's allowed only if it's
    /// still ready a moment later.
    private func ready(_ browser: NWBrowser) {
        guard isLocalNetworkDenied else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard let self, self.browser === browser, case .ready = browser.state else { return }
            self.isLocalNetworkDenied = false
        }
    }

    private func retry(_ failed: NWBrowser) {
        guard browser === failed, restart == nil else { return }
        restart = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard let self, !Task.isCancelled, self.browser === failed else { return }
            self.restart = nil
            self.start()
        }
    }

    public func stop() {
        restart?.cancel()
        restart = nil
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers = [:]
        if !servers.isEmpty {
            servers = []
        }
    }

    private func update(names: Set<String>) {
        if !names.isEmpty {
            isLocalNetworkDenied = false
        }
        servers.removeAll { !names.contains($0.name) }
        for (name, resolver) in resolvers where !names.contains(name) {
            resolver.cancel()
            resolvers[name] = nil
        }
        for name in names where resolvers[name] == nil {
            resolve(name)
        }
    }

    /// Finds [name]'s address, trying again until it's found or gone.
    private func resolve(_ name: String) {
        let resolver = Resolver(name: name, type: Self.serviceType) { [weak self] host, port in
            Task { @MainActor in self?.resolved(name: name, host: host, port: port) }
        }
        resolvers[name] = resolver
        Task { [weak self] in
            try? await Task.sleep(for: Self.resolveTimeout)
            guard let self, self.resolvers[name] === resolver,
                  !self.servers.contains(where: { $0.name == name }) else { return }
            resolver.cancel()
            self.resolve(name)
        }
    }

    private func resolved(name: String, host: String, port: UInt16) {
        guard resolvers[name] != nil else { return }
        let server = DiscoveredServer(name: name, host: host, port: port)
        if let index = servers.firstIndex(where: { $0.name == name }) {
            servers[index] = server
        } else {
            servers.append(server)
            servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

/// Resolves a Bonjour service to an IPv4 address and port, with DNS-SD.
private final class Resolver: @unchecked Sendable {
    typealias Handler = @Sendable (_ host: String, _ port: UInt16) -> Void

    private let handler: Handler
    private let queue = DispatchQueue(label: "org.clementine-player.remote.resolver")
    private var resolveRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private var port: UInt16 = 0

    init(name: String, type: String, handler: @escaping Handler) {
        self.handler = handler
        queue.async { self.resolve(name: name, type: type) }
    }

    func cancel() {
        queue.async {
            self.resolveRef.map(DNSServiceRefDeallocate)
            self.addressRef.map(DNSServiceRefDeallocate)
            self.resolveRef = nil
            self.addressRef = nil
        }
    }

    private var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func resolve(name: String, type: String) {
        let error = DNSServiceResolve(&resolveRef, 0, 0, name, type, "local.", { _, _, _, error, _, hostTarget, port, _, _, context in
            guard error == kDNSServiceErr_NoError, let hostTarget, let context else { return }
            let resolver = Unmanaged<Resolver>.fromOpaque(context).takeUnretainedValue()
            resolver.found(hostTarget: String(cString: hostTarget), port: UInt16(bigEndian: port))
        }, context)
        if error == kDNSServiceErr_NoError, let resolveRef {
            DNSServiceSetDispatchQueue(resolveRef, queue)
        }
    }

    private func found(hostTarget: String, port: UInt16) {
        self.port = port
        addressRef.map(DNSServiceRefDeallocate)
        addressRef = nil
        let error = DNSServiceGetAddrInfo(&addressRef, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4), hostTarget, { _, _, _, error, _, address, _, context in
            guard error == kDNSServiceErr_NoError, let address, let context,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { return }
            let resolver = Unmanaged<Resolver>.fromOpaque(context).takeUnretainedValue()
            var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            resolver.handler(host, resolver.port)
        }, context)
        if error == kDNSServiceErr_NoError, let addressRef {
            DNSServiceSetDispatchQueue(addressRef, queue)
        }
    }
}
