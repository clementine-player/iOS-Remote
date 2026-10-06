import Foundation

/// What the watch shows: Clementine as the phone last saw it. The phone sends it whenever it
/// changes, through WatchConnectivity; the watch can't reach Clementine itself, as watchOS only
/// lets apps open sockets while they stream audio.
public struct WatchNowPlaying: Codable, Equatable, Sendable {
    public enum Connection: String, Codable, Sendable {
        /// Connected, or ready to reconnect at once (as the phone does in the background).
        case connected
        case connecting
        case disconnected
    }

    public var connection: Connection
    /// The Clementine connected to, or the one last connected to; empty if none.
    public var hostName: String
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    /// From 0 to 100.
    public var volume: Int
    /// In seconds; 0 when unknown, as for streams.
    public var length: Int
    /// In seconds, at [positionDate].
    public var position: Int
    public var positionDate: Date
    /// Whether to offer Love (the phone's "Show Last.fm buttons" setting).
    public var showsLove: Bool
    public var isLoved: Bool
    /// The cover, small, as JPEG; nil for a song without one.
    public var cover: Data?

    public init(
        connection: Connection = .disconnected, hostName: String = "", title: String = "", artist: String = "",
        album: String = "", isPlaying: Bool = false, volume: Int = 100, length: Int = 0, position: Int = 0,
        positionDate: Date = .now, showsLove: Bool = false, isLoved: Bool = false, cover: Data? = nil
    ) {
        self.connection = connection
        self.hostName = hostName
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.volume = volume
        self.length = length
        self.position = position
        self.positionDate = positionDate
        self.showsLove = showsLove
        self.isLoved = isLoved
        self.cover = cover
    }

    /// Whether there's a song to show.
    public var hasSong: Bool { !title.isEmpty || !artist.isEmpty }

    /// Where the song should be at [date], counting on from [position] while playing.
    public func position(at date: Date) -> Int {
        guard isPlaying else { return position }
        let elapsed = max(0, Int(date.timeIntervalSince(positionDate)))
        return length > 0 ? min(length, position + elapsed) : position + elapsed
    }

    /// Whether [other] says something new: more than the position moving on as expected.
    public func differs(from other: WatchNowPlaying) -> Bool {
        var a = self, b = other
        a.position = 0; a.positionDate = .distantPast
        b.position = 0; b.positionDate = .distantPast
        return a != b || abs(position(at: .now) - other.position(at: .now)) > 2
    }
}

/// What the watch asks the phone to do.
public enum WatchCommand: Codable, Equatable, Sendable {
    case playPause
    case previous
    case next
    case love
    /// From 0 to 100.
    case setVolume(Int)
    /// Connect if need be, and send what's playing. The watch sends it while it's on screen, which
    /// keeps the phone connected in the background.
    case refresh
}

/// How the messages travel: JSON, under one key of WatchConnectivity's dictionaries.
public enum WatchLinkCoding {
    public static let stateKey = "nowPlaying"

    public static func encode(_ state: WatchNowPlaying) -> [String: Any] {
        [stateKey: encodeData(state)]
    }

    public static func encodeData(_ state: WatchNowPlaying) -> Data {
        (try? JSONEncoder().encode(state)) ?? Data()
    }

    public static func decodeState(_ data: Data?) -> WatchNowPlaying? {
        data.flatMap { try? JSONDecoder().decode(WatchNowPlaying.self, from: $0) }
    }

    public static func encode(_ command: WatchCommand) -> Data {
        (try? JSONEncoder().encode(command)) ?? Data()
    }

    public static func decodeCommand(_ data: Data) -> WatchCommand? {
        try? JSONDecoder().decode(WatchCommand.self, from: data)
    }
}
