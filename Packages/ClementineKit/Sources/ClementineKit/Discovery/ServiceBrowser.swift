import dnssd
import Foundation
import Network
import Synchronization

/// A Clementine found on the network.
public struct DiscoveredServer: Sendable, Hashable, Identifiable {
    /// The name Clementine announces, usually its computer's name.
    public var name: String
    /// Its IPv4 or IPv6 address.
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

    // ServiceBrowser is @MainActor, but deinit may execute off the main actor; keeping active
    // handles in a Mutex lets deinit and stop() tear down NWBrowser and Resolvers thread-safely.
    private let resources = Mutex<Resources>(Resources())

    private struct Resources {
        var browser: NWBrowser?
        var resolvers: [String: Resolver] = [:]
        var restart: Task<Void, Never>?
    }

    /// How long to wait before looking again after browsing fails, or resolving a Clementine.
    static let retryDelay = Duration.seconds(2)
    static let resolveTimeout = Duration.seconds(5)

    public init() {}

    deinit {
        let state = resources.withLock { state -> Resources in
            let old = state
            state = Resources()
            return old
        }
        state.restart?.cancel()
        // Clear handlers before cancel() so teardown callbacks cannot fire or retain closures.
        state.browser?.stateUpdateHandler = nil
        state.browser?.browseResultsChangedHandler = nil
        state.browser?.cancel()
        state.resolvers.values.forEach { $0.cancel() }
    }

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
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let browser else { return }
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
        resources.withLock { $0.browser = browser }
    }

    /// Whether [error] means iOS refused the local network permission.
    nonisolated static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        }
        return false
    }

    private func denied(_ browser: NWBrowser) {
        guard resources.withLock({ $0.browser === browser }) else { return }
        isLocalNetworkDenied = true
    }

    /// A browser is ready just before it's refused the permission, so it's allowed only if it's
    /// still ready a moment later.
    private func ready(_ browser: NWBrowser) {
        guard isLocalNetworkDenied else { return }
        Task { [weak self, weak browser] in
            try? await Task.sleep(for: Self.retryDelay)
            guard let self, let browser,
                  self.resources.withLock({ $0.browser === browser }),
                  case .ready = browser.state else { return }
            self.isLocalNetworkDenied = false
        }
    }

    private func retry(_ failed: NWBrowser) {
        let shouldStart = resources.withLock { $0.browser === failed && $0.restart == nil }
        guard shouldStart else { return }
        let restart = Task { [weak self, weak failed] in
            try? await Task.sleep(for: Self.retryDelay)
            guard let self, !Task.isCancelled, let failed,
                  self.resources.withLock({ $0.browser === failed }) else { return }
            self.resources.withLock { $0.restart = nil }
            self.start()
        }
        resources.withLock { $0.restart = restart }
    }

    public func stop() {
        let old = resources.withLock { state -> Resources in
            let current = state
            state = Resources()
            return current
        }
        old.restart?.cancel()
        old.browser?.stateUpdateHandler = nil
        old.browser?.browseResultsChangedHandler = nil
        old.browser?.cancel()
        old.resolvers.values.forEach { $0.cancel() }
        if !servers.isEmpty {
            servers = []
        }
    }

    private func update(names: Set<String>) {
        if !names.isEmpty {
            isLocalNetworkDenied = false
        }
        servers.removeAll { !names.contains($0.name) }
        let removed = resources.withLock { state -> [Resolver] in
            var dropped: [Resolver] = []
            for (name, resolver) in state.resolvers where !names.contains(name) {
                dropped.append(resolver)
                state.resolvers[name] = nil
            }
            return dropped
        }
        removed.forEach { $0.cancel() }
        for name in names where resources.withLock({ $0.resolvers[name] == nil }) {
            resolve(name)
        }
    }

    /// Finds [name]'s address, trying again until it's found or gone.
    private func resolve(_ name: String) {
        let resolver = Resolver(name: name, type: Self.serviceType) { [weak self] host, port in
            Task { @MainActor in self?.resolved(name: name, host: host, port: port) }
        }
        resources.withLock { $0.resolvers[name] = resolver }
        Task { [weak self] in
            try? await Task.sleep(for: Self.resolveTimeout)
            guard let self,
                  self.resources.withLock({ $0.resolvers[name] === resolver }),
                  !self.servers.contains(where: { $0.name == name }) else { return }
            resolver.cancel()
            self.resolve(name)
        }
    }

    private func resolved(name: String, host: String, port: UInt16) {
        guard resources.withLock({ $0.resolvers[name] != nil }) else { return }
        let server = DiscoveredServer(name: name, host: host, port: port)
        if let index = servers.firstIndex(where: { $0.name == name }) {
            servers[index] = server
        } else {
            servers.append(server)
            servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

/// Resolves a Bonjour service to an IPv4 or IPv6 address and port, with DNS-SD.
private final class Resolver: @unchecked Sendable {
    typealias Handler = @Sendable (_ host: String, _ port: UInt16) -> Void

    // DNSService C callbacks run on `queue` with a raw context pointer. Each active DNSServiceRef
    // retains a CallbackBox (holding only a weak Resolver) and releases it on `queue` upon
    // deallocation, preventing both UAF if Resolver deinits early and strong retain cycles.
    private final class CallbackBox: @unchecked Sendable {
        weak var resolver: Resolver?
        init(_ resolver: Resolver) { self.resolver = resolver }
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "org.clementine-player.remote.resolver")
    private var resolveRef: DNSServiceRef?
    private var resolveBox: Unmanaged<CallbackBox>?
    private var addressRef: DNSServiceRef?
    private var addressBox: Unmanaged<CallbackBox>?
    private var port: UInt16 = 0
    private var ipv4Host: String?
    private var ipv6Host: String?
    private var cancelled = false

    init(name: String, type: String, handler: @escaping Handler) {
        self.handler = handler
        queue.async { self.resolve(name: name, type: type) }
    }

    deinit {
        // Defer DNSServiceRefDeallocate + box.release() onto `queue` using a value copy so
        // teardown serializes after any already-queued C callbacks once `self` is destroyed.
        struct PendingDealloc: @unchecked Sendable {
            let resolveRef: DNSServiceRef?
            let resolveBox: Unmanaged<CallbackBox>?
            let addressRef: DNSServiceRef?
            let addressBox: Unmanaged<CallbackBox>?
        }
        let pending = PendingDealloc(
            resolveRef: resolveRef, resolveBox: resolveBox, addressRef: addressRef, addressBox: addressBox)
        if pending.resolveRef != nil || pending.addressRef != nil {
            queue.async {
                pending.resolveRef.map(DNSServiceRefDeallocate)
                pending.resolveBox?.release()
                pending.addressRef.map(DNSServiceRefDeallocate)
                pending.addressBox?.release()
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.teardownResolve()
            self.teardownAddress()
        }
    }

    private func teardownResolve() {
        resolveRef.map(DNSServiceRefDeallocate)
        resolveRef = nil
        resolveBox?.release()
        resolveBox = nil
    }

    private func teardownAddress() {
        addressRef.map(DNSServiceRefDeallocate)
        addressRef = nil
        addressBox?.release()
        addressBox = nil
    }

    private func resolve(name: String, type: String) {
        guard !cancelled else { return }
        let box = Unmanaged.passRetained(CallbackBox(self))
        let error = DNSServiceResolve(
            &resolveRef, 0, 0, name, type, "local.",
            { _, _, interfaceIndex, error, _, hostTarget, port, _, _, context in
                guard error == kDNSServiceErr_NoError, let hostTarget, let context else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
                box.resolver?.found(
                    hostTarget: String(cString: hostTarget), port: UInt16(bigEndian: port),
                    interfaceIndex: interfaceIndex)
            },
            box.toOpaque())
        if error == kDNSServiceErr_NoError, let resolveRef {
            resolveBox = box
            DNSServiceSetDispatchQueue(resolveRef, queue)
        } else {
            box.release()
        }
    }

    private func found(hostTarget: String, port: UInt16, interfaceIndex: UInt32) {
        guard !cancelled else { return }
        self.port = port
        ipv4Host = nil
        ipv6Host = nil
        teardownAddress()
        let box = Unmanaged.passRetained(CallbackBox(self))
        // Query both IPv4 and IPv6 on the resolved interface so IPv6-only servers resolve and
        // link-local addresses keep their interface scope; track kDNSServiceFlagsAdd so
        // address-removal callbacks clear stale IPs rather than overwriting live hosts.
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let error = DNSServiceGetAddrInfo(
            &addressRef, 0, interfaceIndex, protocols, hostTarget,
            { _, flags, cbInterfaceIndex, error, _, address, _, context in
                guard error == kDNSServiceErr_NoError, let address, let context else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
                let isAdd = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
                box.resolver?.handleAddress(address, isAdd: isAdd, interfaceIndex: cbInterfaceIndex)
            },
            box.toOpaque())
        if error == kDNSServiceErr_NoError, let addressRef {
            addressBox = box
            DNSServiceSetDispatchQueue(addressRef, queue)
        } else {
            box.release()
        }
    }

    private func handleAddress(_ address: UnsafePointer<sockaddr>, isAdd: Bool, interfaceIndex: UInt32) {
        guard !cancelled else { return }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            guard let host = Self.formatIPv4(address) else { return }
            if isAdd {
                ipv4Host = host
            } else if ipv4Host == host {
                ipv4Host = nil
            }
        case AF_INET6:
            guard let host = Self.formatIPv6(address, interfaceIndex: interfaceIndex) else { return }
            if isAdd {
                ipv6Host = host
            } else if ipv6Host == host {
                ipv6Host = nil
            }
        default:
            return
        }
        // Prefer IPv4 on dual-stack hosts so addresses stay stable when both families answer.
        if let best = ipv4Host ?? ipv6Host {
            handler(best, port)
        }
    }

    static func formatIPv4(_ address: UnsafePointer<sockaddr>) -> String? {
        var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func formatIPv6(_ address: UnsafePointer<sockaddr>, interfaceIndex: UInt32) -> String? {
        var sock6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &sock6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // Link-local IPv6 (fe80::/10) requires a %zone suffix to route on the right interface;
        // fall back to DNS-SD's interfaceIndex if sockaddr_in6 leaves sin6_scope_id unset.
        let isLinkLocal = sock6.sin6_addr.__u6_addr.__u6_addr8.0 == 0xFE
            && (sock6.sin6_addr.__u6_addr.__u6_addr8.1 & 0xC0) == 0x80
        let scope = sock6.sin6_scope_id != 0 ? sock6.sin6_scope_id : interfaceIndex
        if isLinkLocal, scope != 0 {
            var ifname = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if if_indextoname(scope, &ifname) != nil {
                let zone = String(decoding: ifname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !zone.isEmpty {
                    return "\(host)%\(zone)"
                }
            }
        }
        return host
    }
}
