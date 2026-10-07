import Foundation
import SwiftProtobuf

/// A message to or from Clementine.
public typealias RemoteMessage = Pb_Remote_Message

/// What a message is for.
public typealias MessageType = Pb_Remote_MsgType

/// A song as Clementine describes it.
public typealias SongMetadata = Pb_Remote_SongMetadata

/// Why Clementine closed the connection.
public typealias DisconnectReason = Pb_Remote_ReasonDisconnect

/// What to download.
public typealias DownloadItem = Pb_Remote_DownloadItem

public enum RemoteProtocol {
    /// The protocol version the app speaks. Clementine older than this is refused.
    public static let version: Int32 = 21

    /// Clementine's port unless it's been changed.
    public static let defaultPort: UInt16 = 5500

    /// Longer messages are taken to be garbage: 50 MB.
    public static let maxMessageLength = 52_428_800
}

public enum ProtocolError: Error, Equatable, Sendable {
    /// The length before a message is negative or too large.
    case invalidLength
    /// The message couldn't be parsed.
    case invalidData
    /// Clementine speaks an older version of the protocol.
    case oldProtocol
}

extension Pb_Remote_Message {
    /// A message of [type], in the app's protocol version, set up by [configure].
    public init(_ type: MessageType, _ configure: (inout Pb_Remote_Message) -> Void = { _ in }) {
        self.init()
        version = RemoteProtocol.version
        self.type = type
        configure(&self)
    }
}

/// Messages are sent as a big-endian 32-bit length and then the message itself.
public enum Framing {
    public static func encode(_ message: RemoteMessage) throws -> Data {
        let body = try message.serializedData()
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    /// The length of the message that follows a 4-byte header.
    public static func length(ofHeader header: Data) throws(ProtocolError) -> Int {
        guard header.count == 4 else { throw .invalidLength }
        let length = header.withUnsafeBytes { Int32(bigEndian: $0.loadUnaligned(as: Int32.self)) }
        guard length >= 0, length <= RemoteProtocol.maxMessageLength else { throw .invalidLength }
        return Int(length)
    }

    /// Parses a message's body, refusing one from an older Clementine.
    public static func decode(_ body: Data) throws(ProtocolError) -> RemoteMessage {
        let message: RemoteMessage
        do {
            message = try RemoteMessage(serializedBytes: body)
        } catch {
            throw .invalidData
        }
        guard message.hasVersion, message.version >= RemoteProtocol.version else {
            throw .oldProtocol
        }
        return message
    }
}

/// The messages the app sends Clementine.
public enum Messages {
    /// Connects; with [renderer], the phone offers itself as an output Clementine can play on.
    /// Clementine without remote streaming ignores it.
    public static func connect(
        authCode: Int32, sendPlaylistSongs: Bool, downloader: Bool, renderer: RendererCapabilities? = nil
    ) -> RemoteMessage {
        RemoteMessage(.connect) {
            $0.requestConnect.authCode = authCode
            $0.requestConnect.sendPlaylistSongs = sendPlaylistSongs
            $0.requestConnect.downloader = downloader
            if let renderer {
                $0.requestConnect.renderer = renderer
            }
        }
    }

    /// Asks Clementine to play on another output: its computer ([Output.local]) or a renderer.
    public static func setOutput(_ id: String) -> RemoteMessage {
        RemoteMessage(.setOutput) { $0.requestSetOutput.outputID = id }
    }

    /// Lists [nodeID]'s children in Clementine's internet services, or the services when it's nil,
    /// from [offset]; Clementine then sends updates of that page while it's the last one asked for.
    public static func browse(_ nodeID: String?, offset: Int = 0) -> RemoteMessage {
        RemoteMessage(.requestBrowse) {
            if let nodeID {
                $0.requestBrowse.nodeID = nodeID
            }
            if offset > 0 {
                $0.requestBrowse.offset = Int32(offset)
            }
        }
    }

    /// Puts internet service nodes on the current playlist, as dragging them from the sidebar does.
    public static func browseAdd(_ nodeIDs: [String], action: BrowseAddAction) -> RemoteMessage {
        RemoteMessage(.requestBrowseAdd) {
            $0.requestBrowseAdd.nodeIds = nodeIDs
            $0.requestBrowseAdd.action = action
        }
    }

    public static func volume(_ percent: Int) -> RemoteMessage {
        RemoteMessage(.setVolume) { $0.requestSetVolume.volume = Int32(percent) }
    }

    public static func shuffle(_ mode: ShuffleMode) -> RemoteMessage {
        RemoteMessage(.shuffle) { $0.shuffle.shuffleMode = mode.proto }
    }

    public static func `repeat`(_ mode: RepeatMode) -> RemoteMessage {
        RemoteMessage(.repeat) { $0.repeat.repeatMode = mode.proto }
    }

    public static func requestPlaylistSongs(_ playlistID: Int32) -> RemoteMessage {
        RemoteMessage(.requestPlaylistSongs) { $0.requestPlaylistSongs.id = playlistID }
    }

    public static func changeSong(index: Int32, playlistID: Int32) -> RemoteMessage {
        RemoteMessage(.changeSong) {
            $0.requestChangeSong.songIndex = index
            $0.requestChangeSong.playlistID = playlistID
        }
    }

    /// Seeks to [seconds] into the song.
    public static func trackPosition(_ seconds: Int) -> RemoteMessage {
        RemoteMessage(.setTrackPosition) { $0.requestSetTrackPosition.position = Int32(seconds) }
    }

    /// Rates the current song, from 0 to 1.
    public static func rate(_ rating: Float) -> RemoteMessage {
        RemoteMessage(.rateSong) { $0.requestRateSong.rating = rating }
    }

    /// Adds [urls] to a playlist; with [playNow], Clementine plays the first of them. With
    /// [enqueue], they're queued after anything queued already; with [enqueueNext], in front of it.
    public static func insertURLs(
        _ urls: [String], playlistID: Int32, playNow: Bool = false, enqueue: Bool = false, enqueueNext: Bool = false
    ) -> RemoteMessage {
        RemoteMessage(.insertUrls) {
            $0.requestInsertUrls.playlistID = playlistID
            $0.requestInsertUrls.urls = urls
            $0.requestInsertUrls.playNow = playNow
            $0.requestInsertUrls.enqueue = enqueue
            $0.requestInsertUrls.enqueueNext = enqueueNext
        }
    }

    /// Adds [songs] to a playlist; with [playNow], Clementine plays the first of them. With
    /// [enqueue], they're queued after anything queued already; with [enqueueNext], in front of it.
    public static func insertSongs(
        _ songs: [SongMetadata], playlistID: Int32, playNow: Bool = false, enqueue: Bool = false, enqueueNext: Bool = false
    ) -> RemoteMessage {
        RemoteMessage(.insertUrls) {
            $0.requestInsertUrls.playlistID = playlistID
            $0.requestInsertUrls.songs = songs
            $0.requestInsertUrls.playNow = playNow
            $0.requestInsertUrls.enqueue = enqueue
            $0.requestInsertUrls.enqueueNext = enqueueNext
        }
    }

    /// Removes the songs at [indices] of a playlist.
    public static func removeSongs(_ indices: [Int32], playlistID: Int32) -> RemoteMessage {
        RemoteMessage(.removeSongs) {
            $0.requestRemoveSongs.playlistID = playlistID
            $0.requestRemoveSongs.songs = indices
        }
    }

    public static func closePlaylist(_ playlistID: Int32) -> RemoteMessage {
        RemoteMessage(.closePlaylist) { $0.requestClosePlaylist.playlistID = playlistID }
    }

    /// Creates a playlist called [name], which Clementine then shows. Needs Clementine 1.4.
    public static func createPlaylist(named name: String) -> RemoteMessage {
        RemoteMessage(.updatePlaylist) {
            $0.requestUpdatePlaylist.createNewPlaylist = true
            $0.requestUpdatePlaylist.newPlaylistName = name
        }
    }

    public static func globalSearch(_ query: String) -> RemoteMessage {
        RemoteMessage(.globalSearch) { $0.requestGlobalSearch.query = query }
    }

    public static func downloadSongs(_ item: DownloadItem, playlistID: Int32 = -1, urls: [String] = []) -> RemoteMessage {
        RemoteMessage(.downloadSongs) {
            $0.requestDownloadSongs.downloadItem = item
            $0.requestDownloadSongs.playlistID = playlistID
            $0.requestDownloadSongs.urls = urls
        }
    }

    public static func songOfferResponse(accepted: Bool) -> RemoteMessage {
        RemoteMessage(.songOfferResponse) { $0.responseSongOffer.accepted = accepted }
    }
}
