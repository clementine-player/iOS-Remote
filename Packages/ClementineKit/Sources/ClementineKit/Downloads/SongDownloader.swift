import Foundation

/// Where and how downloaded songs are saved.
public struct DownloadOptions: Sendable {
    /// The folder songs are saved under.
    public var directory: URL
    public var replaceExisting = false
    /// Save a playlist's songs in a folder named after it.
    public var playlistFolder = false
    /// Save each song in a folder named after its artist…
    public var artistFolder = true
    /// …and within that, its album.
    public var albumFolder = true

    public init(directory: URL) {
        self.directory = directory
    }

    public init(directory: URL, settings: Settings) {
        self.directory = directory
        replaceExisting = settings.replaceExisting
        playlistFolder = settings.playlistFolder
        artistFolder = settings.artistFolder
        albumFolder = settings.albumFolder
    }
}

/// A song saved on the phone.
public struct DownloadedSong: Sendable, Hashable {
    public var title: String
    public var artist: String
    public var album: String
    public var file: URL
}

/// How a download is going.
public struct DownloadStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case starting
        /// Clementine is converting songs: this many of this many done.
        case transcoding(done: Int, total: Int)
        case downloading
        case finished(DownloadFailure?)
    }

    public var state = State.starting
    /// The song being downloaded, counting from 1, and how many there are.
    public var fileNumber = 0
    public var fileCount = 0
    public var title = ""
    public var artist = ""
    public var album = ""
    /// From 0 to 1.
    public var progress = 0.0
    public var bytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var songs: [DownloadedSong] = []

    public init() {}
}

/// Downloads songs from Clementine, over a connection of its own: Clementine offers each song,
/// the app accepts it unless it has it already, then Clementine sends it in chunks.
public struct SongDownloader: Sendable {
    public let endpoint: Endpoint
    public let authCode: Int32
    public let request: RemoteMessage
    /// The playlist's name, when downloading a playlist.
    public let playlistName: String?
    public let options: DownloadOptions

    public init(endpoint: Endpoint, authCode: Int32, request: RemoteMessage, playlistName: String?, options: DownloadOptions) {
        self.endpoint = endpoint
        self.authCode = authCode
        self.request = request
        self.playlistName = playlistName
        self.options = options
    }

    /// Downloads, telling [update] how it's going, and returns the final status.
    public func run(update: @escaping @Sendable (DownloadStatus) -> Void) async -> DownloadStatus {
        var status = DownloadStatus()
        update(status)
        let failure = await download(&status, update)
        status.state = .finished(failure)
        if failure == nil {
            status.progress = 1
        }
        update(status)
        return status
    }

    private func download(_ status: inout DownloadStatus, _ update: @Sendable (DownloadStatus) -> Void) async -> DownloadFailure? {
        let channel = MessageChannel(endpoint: endpoint)
        do {
            try await channel.open()
            try await channel.send(Messages.connect(authCode: authCode, sendPlaylistSongs: false, downloader: true))
            try await channel.send(request)
        } catch {
            channel.cancel()
            return Task.isCancelled ? .cancelled : .connection
        }
        defer { channel.cancel() }

        var pending: (url: URL, handle: FileHandle)?
        var song = SongMetadata()
        defer {
            // A partly written song is no use.
            if let pending {
                try? pending.handle.close()
                try? FileManager.default.removeItem(at: pending.url)
            }
        }

        while true {
            let message: RemoteMessage
            do {
                message = try await channel.receive()
            } catch {
                return Task.isCancelled ? .cancelled : .connection
            }
            switch message.type {
            case .disconnect:
                return DownloadFailure(message.responseDisconnect)
            case .downloadQueueEmpty:
                try? await channel.send(RemoteMessage(.disconnect))
                return nil
            case .downloadTotalSize:
                status.totalBytes = Int64(message.responseDownloadTotalSize.totalSize)
                update(status)
            case .transcodingFiles:
                let transcoding = message.responseTranscoderStatus
                status.state = .transcoding(done: Int(transcoding.processed), total: Int(transcoding.total))
                update(status)
            case .songFileChunk:
                let chunk = message.responseSongFileChunk
                if chunk.chunkNumber == 0 {
                    // An offer of the next song.
                    song = chunk.songMetadata
                    let file = file(for: song)
                    let exists = FileManager.default.fileExists(atPath: file.path)
                    let accept = !exists || options.replaceExisting
                    do {
                        try await channel.send(Messages.songOfferResponse(accepted: accept))
                    } catch {
                        return .connection
                    }
                    if !accept {
                        // Already here: listed with the downloaded songs.
                        status.songs.append(DownloadedSong(title: song.title, artist: song.artist, album: song.album, file: file))
                        status.bytes += Int64(chunk.size)
                    }
                    status.state = .downloading
                    report(chunk, song, &status)
                    update(status)
                    continue
                }
                if pending == nil {
                    if let free = LibraryStore.freeSpace(at: options.directory), free < Int64(chunk.size) {
                        return .insufficientSpace
                    }
                    let file = file(for: song)
                    do {
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? FileManager.default.removeItem(at: file)
                        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return .cantSave }
                        pending = (file, try FileHandle(forWritingTo: file))
                    } catch {
                        return .cantSave
                    }
                }
                do {
                    try pending?.handle.write(contentsOf: chunk.data)
                } catch {
                    return .cantSave
                }
                status.bytes += Int64(chunk.data.count)
                if chunk.chunkNumber == chunk.chunkCount, let done = pending {
                    try? done.handle.close()
                    pending = nil
                    status.songs.append(DownloadedSong(title: song.title, artist: song.artist, album: song.album, file: done.url))
                }
                report(chunk, song, &status)
                update(status)
            default:
                break
            }
        }
    }

    private func report(_ chunk: Pb_Remote_ResponseSongFileChunk, _ song: SongMetadata, _ status: inout DownloadStatus) {
        let files = Double(max(chunk.fileCount, 1))
        if chunk.chunkNumber > 0 {
            status.progress = (Double(chunk.fileNumber - 1) / files
                + Double(chunk.chunkNumber) / Double(max(chunk.chunkCount, 1)) / files)
        }
        status.fileNumber = Int(chunk.fileNumber)
        status.fileCount = Int(chunk.fileCount)
        status.title = song.title
        status.artist = song.artist
        status.album = song.album
    }

    /// Where [song] is saved: under the playlist, artist and album folders the options ask for.
    func file(for song: SongMetadata) -> URL {
        var folder = options.directory
        func append(_ name: String) {
            let clean = Self.clean(name).trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                folder.append(path: clean, directoryHint: .isDirectory)
            }
        }
        if let playlistName, options.playlistFolder {
            append(playlistName)
        }
        if options.artistFolder {
            append(song.albumartist.isEmpty ? song.artist : song.albumartist)
            if options.albumFolder {
                append(song.album)
            }
        }
        var name = Self.clean(song.filename)
        if name.isEmpty {
            name = Self.clean(song.title)
        }
        return folder.appending(path: name, directoryHint: .notDirectory)
    }

    /// Drops the characters the Android app keeps out of file names, except "-", which is harmless.
    static func clean(_ name: String) -> String {
        name.filter { !"\\~#%&*{}/:<>?|\"".contains($0) }
    }
}
