import Foundation
import Testing
@testable import ClementineKit

struct SettingsTests {
    @Test func connectsAutomaticallyByDefault() {
        #expect(Settings(suiteName: UUID().uuidString).autoConnect)
    }

    @Test func remembersTheAddressAndName() {
        let settings = Settings(suiteName: UUID().uuidString)
        settings.remember(host: "192.168.1.20", name: "studio-pc")
        #expect(settings.lastHost == "192.168.1.20")
        #expect(settings.lastServerName == "studio-pc")
        #expect(settings.knownHosts == ["192.168.1.20"])
    }

    @Test func forgetsTheNameForAnAddressTypedIn() {
        let settings = Settings(suiteName: UUID().uuidString)
        settings.remember(host: "192.168.1.20", name: "studio-pc")
        settings.remember(host: "10.0.0.5")
        #expect(settings.lastHost == "10.0.0.5")
        #expect(settings.lastServerName == "")
        #expect(settings.knownHosts == ["10.0.0.5", "192.168.1.20"])
    }
}
