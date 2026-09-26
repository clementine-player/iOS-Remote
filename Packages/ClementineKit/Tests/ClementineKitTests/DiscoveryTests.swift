import Foundation
import Network
import Testing
@testable import ClementineKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DiscoveryTests {

    @Test func findsAClementineThatAnnouncesItself() async throws {
        let name = "Test Clementine \(UUID().uuidString.prefix(8))"
        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: name, type: ServiceBrowser.serviceType)
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        defer { listener.cancel() }

        let browser = ServiceBrowser()
        browser.start()
        defer { browser.stop() }
        try await eventually(timeout: .seconds(20)) {
            browser.servers.contains { $0.name == name }
        }
        let server = try #require(browser.servers.first { $0.name == name })
        #expect(server.port == listener.port?.rawValue)
        #expect(IPv4Address(server.host) != nil)
    }
}
