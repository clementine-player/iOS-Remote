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

    private var browser: NWBrowser?
    private var resolvers: [String: Resolver] = [:]

    public init() {}

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
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers = [:]
        servers = []
    }

    private func update(names: Set<String>) {
        servers.removeAll { !names.contains($0.name) }
        for (name, resolver) in resolvers where !names.contains(name) {
            resolver.cancel()
            resolvers[name] = nil
        }
        for name in names where resolvers[name] == nil {
            resolvers[name] = Resolver(name: name, type: Self.serviceType) { [weak self] host, port in
                Task { @MainActor in self?.resolved(name: name, host: host, port: port) }
            }
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
