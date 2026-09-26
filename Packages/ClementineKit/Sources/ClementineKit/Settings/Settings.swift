import Foundation

/// The app's settings and saved state, by their keys in UserDefaults. The keys are the Android
/// app's.
public enum SettingKey {
    // Player
    public static let volumeButtons = "pref_volumekey"
    public static let volumeStep = "pref_volume_inc"
    public static let showLastFM = "pref_show_lastfm"
    // Library
    public static let libraryGrouping = "pref_library_grouping"
    public static let librarySorting = "pref_library_sorting"
    // Downloads
    public static let wifiOnly = "pref_dl_wifi_only"
    public static let replaceExisting = "pref_dl_override"
    public static let playlistFolder = "pref_dl_pl_save_own_dir"
    public static let artistFolder = "pref_dl_artist_dir"
    public static let albumFolder = "pref_dl_album_dir"
    // Connection
    public static let autoConnect = "pref_autoconnect"
    public static let port = "pref_port"
    // Advanced
    public static let keepScreenOn = "pref_keep_screen_on"

    // Saved state
    public static let lastHost = "save_clementine_ip"
    public static let knownHosts = "known_ips"
    public static let lastAuthCode = "last_auth_code"
    public static let libraryHost = "library_ip"
    public static let firstLaunch = "first_call"
}

/// Reads the settings, with their defaults.
public struct Settings: Sendable {
    public static var defaults: [String: Any] { [
        SettingKey.volumeButtons: true,
        SettingKey.volumeStep: 10,
        SettingKey.showLastFM: true,
        SettingKey.libraryGrouping: LibraryGrouping.artistAlbum.rawValue,
        SettingKey.librarySorting: LibrarySorting.ascending.rawValue,
        SettingKey.wifiOnly: false,
        SettingKey.replaceExisting: false,
        SettingKey.playlistFolder: false,
        SettingKey.artistFolder: true,
        SettingKey.albumFolder: true,
        SettingKey.autoConnect: false,
        SettingKey.port: Int(RemoteProtocol.defaultPort),
        SettingKey.keepScreenOn: false,
        SettingKey.firstLaunch: true,
    ] }

    private let storeName: String?

    /// Settings in [store], the standard defaults when nil.
    public init(suiteName: String? = nil) {
        storeName = suiteName
        store.register(defaults: Self.defaults)
    }

    public var store: UserDefaults {
        storeName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public var volumeButtons: Bool { store.bool(forKey: SettingKey.volumeButtons) }
    public var volumeStep: Int { max(1, min(20, store.integer(forKey: SettingKey.volumeStep))) }
    public var showLastFM: Bool { store.bool(forKey: SettingKey.showLastFM) }
    public var libraryGrouping: LibraryGrouping {
        LibraryGrouping(rawValue: store.string(forKey: SettingKey.libraryGrouping) ?? "") ?? .artistAlbum
    }
    public var librarySorting: LibrarySorting {
        LibrarySorting(rawValue: store.string(forKey: SettingKey.librarySorting) ?? "") ?? .ascending
    }
    public var wifiOnly: Bool { store.bool(forKey: SettingKey.wifiOnly) }
    public var replaceExisting: Bool { store.bool(forKey: SettingKey.replaceExisting) }
    public var playlistFolder: Bool { store.bool(forKey: SettingKey.playlistFolder) }
    public var artistFolder: Bool { store.bool(forKey: SettingKey.artistFolder) }
    public var albumFolder: Bool { store.bool(forKey: SettingKey.albumFolder) }
    public var autoConnect: Bool { store.bool(forKey: SettingKey.autoConnect) }
    public var port: UInt16 {
        UInt16(exactly: store.integer(forKey: SettingKey.port)) ?? RemoteProtocol.defaultPort
    }
    public var keepScreenOn: Bool { store.bool(forKey: SettingKey.keepScreenOn) }

    public var lastHost: String {
        get { store.string(forKey: SettingKey.lastHost) ?? "" }
        nonmutating set { store.set(newValue, forKey: SettingKey.lastHost) }
    }
    /// Addresses connected to before, most recent first.
    public var knownHosts: [String] {
        get { store.stringArray(forKey: SettingKey.knownHosts) ?? [] }
        nonmutating set { store.set(newValue, forKey: SettingKey.knownHosts) }
    }
    public var lastAuthCode: Int32 {
        get { Int32(truncatingIfNeeded: store.integer(forKey: SettingKey.lastAuthCode)) }
        nonmutating set { store.set(Int(newValue), forKey: SettingKey.lastAuthCode) }
    }
    /// The Clementine the library on the phone came from.
    public var libraryHost: String {
        get { store.string(forKey: SettingKey.libraryHost) ?? "" }
        nonmutating set { store.set(newValue, forKey: SettingKey.libraryHost) }
    }
    public var isFirstLaunch: Bool {
        get { store.bool(forKey: SettingKey.firstLaunch) }
        nonmutating set { store.set(newValue, forKey: SettingKey.firstLaunch) }
    }

    /// Remembers an address connected to.
    public func remember(host: String) {
        guard !host.isEmpty else { return }
        lastHost = host
        knownHosts = [host] + knownHosts.filter { $0 != host }
    }
}

/// How the library's levels group songs.
public enum LibraryGrouping: String, Sendable, CaseIterable {
    case artist = "artist"
    case artistAlbum = "artist-album"
    case albumArtistAlbum = "albumartist-album"
    case artistYear = "artist-year"
    case album = "album"
    case genreAlbum = "genre-album"
    case genreArtistAlbum = "genre-artist-album"

    /// The fields grouped by, top down, then the songs' titles.
    public var fields: [String] {
        switch self {
        case .artist: ["artist", "title"]
        case .artistAlbum: ["artist", "album", "title"]
        case .albumArtistAlbum: ["albumartist", "album", "title"]
        case .artistYear: ["artist", "year", "title"]
        case .album: ["album", "title"]
        case .genreAlbum: ["genre", "album", "title"]
        case .genreArtistAlbum: ["genre", "artist", "album", "title"]
        }
    }
}

public enum LibrarySorting: String, Sendable, CaseIterable {
    case ascending = "ASC"
    case descending = "DESC"
}
