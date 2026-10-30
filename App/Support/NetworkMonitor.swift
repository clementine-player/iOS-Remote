import ClementineKit
import Foundation
import Network

/// Whether the phone is on Wi-Fi, with a private address: what Clementine needs.
@MainActor
@Observable
final class NetworkMonitor {
    enum Problem: Equatable {
        case notOnWiFi
        case noPrivateAddress
    }

    private(set) var isOnWiFi = true
    /// Whether the network is mobile data, or a hotspot, as iOS sees it.
    private(set) var isExpensive = false
    /// Whether Low Data Mode is on for the network.
    private(set) var isConstrained = false
    private var monitor: NWPathMonitor?

    init() {
        start()
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                self?.isOnWiFi = wifi
                self?.isExpensive = expensive
                self?.isConstrained = constrained
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    /// Whether songs can download over the network the phone is on, as [network] says.
    func allows(_ network: DownloadNetwork) -> Bool {
        network.allows(expensive: isExpensive, constrained: isConstrained)
    }

    /// What's wrong with the network for reaching Clementine, if anything.
    var problem: Problem? {
        if !isOnWiFi {
            return .notOnWiFi
        }
        if !Self.hasPrivateIPv4Address() {
            return .noPrivateAddress
        }
        return nil
    }

    /// Whether any interface has a private (site-local) IPv4 address.
    nonisolated static func hasPrivateIPv4Address() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if isPrivate(ip) {
                return true
            }
        }
        return false
    }

    /// 10/8, 172.16/12 and 192.168/16.
    nonisolated static func isPrivate(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip >> 20 == 0xAC1 || ip >> 16 == 0xC0A8
    }
}
