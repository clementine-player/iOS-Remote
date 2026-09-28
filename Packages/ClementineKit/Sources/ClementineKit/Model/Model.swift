import Foundation

/// Whether Clementine is playing.
public enum PlayState: Sendable, Equatable {
    case playing, paused, stopped
}

public enum ShuffleMode: Sendable, CaseIterable, Equatable {
    case off, all, insideAlbum, albums

    /// The mode after this one, as tapping shuffle cycles through them.
    public var next: ShuffleMode {
        switch self {
        case .off: .all
        case .all: .insideAlbum
        case .insideAlbum: .albums
        case .albums: .off
        }
    }

    init(_ proto: Pb_Remote_ShuffleMode) {
        switch proto {
        case .shuffleOff: self = .off
        case .shuffleAll: self = .all
        case .shuffleInsideAlbum: self = .insideAlbum
        case .shuffleAlbums: self = .albums
        }
    }

    var proto: Pb_Remote_ShuffleMode {
        switch self {
        case .off: .shuffleOff
        case .all: .shuffleAll
        case .insideAlbum: .shuffleInsideAlbum
        case .albums: .shuffleAlbums
        }
    }
}

public enum RepeatMode: Sendable, CaseIterable, Equatable {
    case off, track, album, playlist

    /// The mode after this one, as tapping repeat cycles through them.
    public var next: RepeatMode {
        switch self {
        case .off: .track
        case .track: .album
        case .album: .playlist
        case .playlist: .off
        }
    }

    init(_ proto: Pb_Remote_RepeatMode) {
        switch proto {
        case .repeatOff: self = .off
        case .repeatTrack: self = .track
        case .repeatAlbum: self = .album
        case .repeatPlaylist: self = .playlist
        // Clementine's other modes stop after each song or play its start: the app shows them
        // as not repeating.
        case .repeatOneByOne, .repeatIntro: self = .off
        }
    }

    var proto: Pb_Remote_RepeatMode {
        switch self {
        case .off: .repeatOff
        case .track: .repeatTrack
        case .album: .repeatAlbum
        case .playlist: .repeatPlaylist
        }
    }
}

/// A song, in a playlist or playing.
public struct Song: Sendable, Hashable {
    /// Clementine's id for the song.
    public var id: Int32
    /// Its row in its playlist.
    public var index: Int32
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var genre: String
    /// As Clementine formats it; may be empty.
    public var year: String
    public var track: Int
    public var disc: Int
    public var playCount: Int
    /// In seconds; 0 when unknown.
    public var length: Int
    /// As Clementine formats it, such as "5:00".
    public var prettyLength: String
    public var filename: String
    /// In bytes.
    public var size: Int64
    /// False for streams.
    public var isLocal: Bool
    /// From 0 to 1.
    public var rating: Float
    public var url: String
    /// The cover as Clementine sent it (compressed), if any.
    public var artData: Data?
    /// The whole description, for adding the song to a playlist.
    public var metadata: SongMetadata

    public init(_ metadata: SongMetadata) {
        id = metadata.id
        index = metadata.index
        title = metadata.title
        artist = metadata.artist
        album = metadata.album
        albumArtist = metadata.albumartist
        genre = metadata.genre
        year = metadata.prettyYear
        track = Int(metadata.track)
        disc = Int(metadata.disc)
        playCount = Int(metadata.playcount)
        length = Int(metadata.length)
        prettyLength = metadata.prettyLength
        filename = metadata.filename
        size = Int64(metadata.fileSize)
        isLocal = metadata.isLocal
        rating = metadata.rating
        url = metadata.url
        artData = metadata.hasArt && !metadata.art.isEmpty ? metadata.art : nil
        var withoutArt = metadata
        withoutArt.clearArt()
        self.metadata = withoutArt
    }

    /// Matches a filter in the title, artist or album, ignoring case.
    public func matches(_ filter: String) -> Bool {
        title.localizedCaseInsensitiveContains(filter)
            || artist.localizedCaseInsensitiveContains(filter)
            || album.localizedCaseInsensitiveContains(filter)
    }
}

/// One of Clementine's open playlists.
public struct Playlist: Sendable, Hashable, Identifiable {
    public var id: Int32
    public var name: String
    public var itemCount: Int
    public var isClosed: Bool

    public init(id: Int32, name: String, itemCount: Int = 0, isClosed: Bool = false) {
        self.id = id
        self.name = name
        self.itemCount = itemCount
        self.isClosed = isClosed
    }
}

/// Lyrics for the song playing, from one provider.
public struct Lyrics: Sendable, Hashable {
    public var provider: String
    public var title: String
    public var content: String

    public init(provider: String, title: String, content: String) {
        self.provider = provider
        self.title = title
        self.content = content
    }

    /// The best of several providers' lyrics: for now, the longest.
    public static func best(of lyrics: [Lyrics]) -> Lyrics? {
        lyrics.reduce(nil) { best, next in
            guard let best else { return next }
            return next.content.count > best.content.count ? next : best
        }
    }
}

/// Where Clementine is.
public struct Endpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = RemoteProtocol.defaultPort) {
        self.host = host
        self.port = port
    }
}

/// Somewhere Clementine can play: its own computer, or a renderer such as this phone (remote
/// streaming).
public struct Output: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// Connected, and can be chosen.
        case available
        /// Playback is moving to it.
        case activating
        /// Where Clementine plays now.
        case active
    }

    /// [Output.local] for Clementine's computer, otherwise the renderer's id.
    public var id: String
    public var name: String
    public var state: State

    /// The id of Clementine's own computer.
    public static let local = "local"

    public init(id: String, name: String, state: State) {
        self.id = id
        self.name = name
        self.state = state
    }

    init(_ proto: Pb_Remote_Output) {
        id = proto.outputID
        name = proto.displayName
        switch proto.state {
        case .active: state = .active
        case .activating: state = .activating
        default: state = .available
        }
    }

    public var isLocal: Bool { id == Output.local }
}
