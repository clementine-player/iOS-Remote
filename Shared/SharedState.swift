import ClementineKit
import Foundation

/// What the app shares with its widget and Shortcuts actions: which Clementine to talk to, and
/// what it was playing when the app last saw it.
struct SharedState: Codable, Equatable {
    /// From the Info.plist, as it depends on the team signing the app (Config/Signing.xcconfig).
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as! String
    private static let key = "shared_state"

    var host = ""
    var port = RemoteProtocol.defaultPort
    var authCode: Int32 = 0
    var title = ""
    var artist = ""
    var isPlaying = false

    var endpoint: Endpoint? {
        host.isEmpty ? nil : Endpoint(host: host, port: port)
    }

    private static var store: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func load() -> SharedState {
        guard let data = store.data(forKey: key),
              let state = try? JSONDecoder().decode(SharedState.self, from: data) else { return SharedState() }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.store.set(data, forKey: Self.key)
    }
}
