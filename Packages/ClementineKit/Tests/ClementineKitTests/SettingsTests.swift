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

    @Test func theWifiOnlySwitchDecidesTheNetworkUntilOneIsChosen() {
        let settings = Settings(suiteName: UUID().uuidString)
        #expect(settings.downloadNetwork == .any)

        settings.store.set(true, forKey: SettingKey.wifiOnly)
        #expect(settings.downloadNetwork == .wifiOnly)

        settings.store.set(DownloadNetwork.mobileData.rawValue, forKey: SettingKey.downloadNetwork)
        #expect(settings.downloadNetwork == .mobileData)

        settings.store.set("satellite", forKey: SettingKey.downloadNetwork)
        #expect(settings.downloadNetwork == .wifiOnly)
    }

    @Test func eachNetworkChoiceAllowsItsNetworks() {
        #expect(DownloadNetwork.wifiOnly.allows(expensive: false, constrained: false))
        #expect(!DownloadNetwork.wifiOnly.allows(expensive: true, constrained: false))
        #expect(!DownloadNetwork.wifiOnly.allows(expensive: false, constrained: true))
        #expect(DownloadNetwork.mobileData.allows(expensive: true, constrained: false))
        #expect(!DownloadNetwork.mobileData.allows(expensive: true, constrained: true))
        #expect(DownloadNetwork.any.allows(expensive: true, constrained: true))
    }
}
