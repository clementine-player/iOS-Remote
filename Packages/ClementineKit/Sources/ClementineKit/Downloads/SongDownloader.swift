import Foundation

/// Where and how downloaded songs are saved.
public struct DownloadOptions: Sendable {
    /// The folder songs are saved under.
    public var directory: URL
    /// Download again a song saved under the same name, when it differs from the one offered.
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
    public let receiveTimeout: Duration

    public init(
        endpoint: Endpoint, authCode: Int32, request: RemoteMessage, playlistName: String?,
        options: DownloadOptions, receiveTimeout: Duration = .seconds(60)
    ) {
        self.endpoint = endpoint
        self.authCode = authCode
        self.request = request
        self.playlistName = playlistName
        self.options = options
        self.receiveTimeout = receiveTimeout
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

    private struct PendingFile {
        let destination: URL
        let partial: URL
        let handle: FileHandle
        let expectedSize: Int64
        var writtenBytes: Int64 = 0
    }

    private func discard(_ pending: inout PendingFile?) {
        guard let active = pending else { return }
        pending = nil
        try? active.handle.close()
        try? FileManager.default.removeItem(at: active.partial)
    }

    // Stage downloads in a hidden .part file and verify expectedSize before replacing the
    // destination atomically so cancelled/broken transfers never clobber an existing song.
    private func commit(_ pending: inout PendingFile?, song: SongMetadata, status: inout DownloadStatus) -> DownloadFailure? {
        guard let active = pending else { return nil }
        pending = nil
        try? active.handle.close()
        // Skip byte-count verification when the server omitted or zeroed chunk.size.
        if active.expectedSize > 0 {
            guard active.writtenBytes == active.expectedSize else {
                try? FileManager.default.removeItem(at: active.partial)
                return .connection
            }
        }
        do {
            if FileManager.default.fileExists(atPath: active.destination.path) {
                _ = try FileManager.default.replaceItemAt(active.destination, withItemAt: active.partial)
            } else {
                try FileManager.default.moveItem(at: active.partial, to: active.destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: active.partial)
            return .cantSave
        }
        status.songs.append(DownloadedSong(title: song.title, artist: song.artist, album: song.album, file: active.destination))
        return nil
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

        var pending: PendingFile?
        var song = SongMetadata()
        var offeredSize: Int64 = 0
        defer {
            // A partly written song is discarded without overwriting any existing copy.
            discard(&pending)
        }

        while true {
            let message: RemoteMessage
            do {
                message = try await channel.receive(timeout: receiveTimeout)
            } catch {
                return Task.isCancelled ? .cancelled : .connection
            }
            switch message.type {
            case .disconnect:
                return DownloadFailure(message.responseDisconnect)
            case .downloadQueueEmpty:
                // Commit (or reject if truncated) any open file here and on chunk 0: older
                // Clementine servers (using integer division + 1 for chunk_count) overcount by 1
                // on exact 100 KB multiples and never emit chunkNumber == chunkCount.
                if let failure = commit(&pending, song: song, status: &status) {
                    return failure
                }
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
                    if let failure = commit(&pending, song: song, status: &status) {
                        return failure
                    }
                    // An offer of the next song.
                    song = chunk.songMetadata
                    offeredSize = Int64(chunk.size)
                    let file = file(for: song)
                    let accept = Self.shouldDownload(
                        savedSize: Self.size(of: file), offeredSize: offeredSize,
                        replaceExisting: options.replaceExisting)
                    do {
                        try await channel.send(Messages.songOfferResponse(accepted: accept))
                    } catch {
                        return Task.isCancelled ? .cancelled : .connection
                    }
                    if !accept {
                        // Already here: listed with the downloaded songs.
                        status.songs.append(DownloadedSong(title: song.title, artist: song.artist, album: song.album, file: file))
                        status.bytes += offeredSize
                    }
                    status.state = .downloading
                    report(chunk, song, &status)
                    update(status)
                    continue
                }
                if pending == nil {
                    // With convert_lossless enabled, chunk 0 carries the original .flac metadata
                    // and size while chunk 1 switches to the transcoded extension and size.
                    if chunk.hasSongMetadata {
                        song = chunk.songMetadata
                    }
                    let expectedSize = chunk.size > 0 ? Int64(chunk.size) : offeredSize
                    offeredSize = 0
                    if let free = LibraryStore.freeSpace(at: options.directory), free < expectedSize {
                        return .insufficientSpace
                    }
                    let destination = file(for: song)
                    let folder = destination.deletingLastPathComponent()
                    // Leading dot hides in-progress transfers from SavedSongs until commit().
                    let partial = folder.appending(path: ".\(UUID().uuidString).part")
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { return .cantSave }
                        let handle = try FileHandle(forWritingTo: partial)
                        pending = PendingFile(destination: destination, partial: partial, handle: handle, expectedSize: expectedSize)
                    } catch {
                        try? FileManager.default.removeItem(at: partial)
                        return .cantSave
                    }
                }
                do {
                    try pending?.handle.write(contentsOf: chunk.data)
                } catch {
                    return .cantSave
                }
                pending?.writtenBytes += Int64(chunk.data.count)
                status.bytes += Int64(chunk.data.count)
                if chunk.chunkCount > 0, chunk.chunkNumber >= chunk.chunkCount {
                    if let failure = commit(&pending, song: song, status: &status) {
                        return failure
                    }
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

    /// Whether to download an offered song: if it isn't saved yet, or if existing files are to be
    /// replaced and the one saved isn't the same. The offer only tells the file's size, so a saved
    /// song of the same size is taken to be the same: downloading a playlist again then only
    /// downloads the songs that are new or changed.
    static func shouldDownload(savedSize: Int64?, offeredSize: Int64, replaceExisting: Bool) -> Bool {
        guard let savedSize else { return true }
        return replaceExisting && savedSize != offeredSize
    }

    /// The size of the file saved at [file], or nil if there's none.
    static func size(of file: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Where [song] is saved: under the playlist, artist and album folders the options ask for.
    func file(for song: SongMetadata) -> URL {
        var folder = options.directory
        func append(_ name: String) {
            // Stripping dots can expose whitespace or vice versa (e.g. " . . x"); repeat until stable.
            var candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
            while true {
                let next = Self.clean(String(candidate.drop(while: { $0 == "." || $0.isWhitespace })))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if next == candidate { break }
                candidate = next
            }
            if !candidate.isEmpty {
                folder.append(path: candidate, directoryHint: .isDirectory)
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
        if name.isEmpty {
            // Never use an empty name: appending "" to `folder` resolves to `folder` itself.
            name = "Untitled"
        }
        return folder.appending(path: name, directoryHint: .notDirectory)
    }

    /// Drops control characters and the characters the Android app keeps out of file names,
    /// except "-", which is harmless. Leading dots and dot-only/blank names are dropped so no song
    /// is saved hidden or outside the folder, while existing leading spaces remain intact.
    static func clean(_ name: String) -> String {
        var clean = String(name.filter {
            $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } && !"\\~#%&*{}/:<>?|\"".contains($0)
        })
        if clean.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy({ $0 == "." }) {
            return ""
        }
        while clean.first == "." {
            clean.removeFirst()
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : clean
    }
}
