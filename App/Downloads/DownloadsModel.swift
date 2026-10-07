import ClementineKit
import SwiftUI
import UserNotifications

/// Songs downloading from Clementine, and those downloaded.
@MainActor
@Observable
final class DownloadsModel {
    enum Kind: Equatable {
        case song, album, songs
        case playlist(String)
    }

    struct Job: Identifiable {
        let id: Int
        let kind: Kind
        var status = DownloadStatus()
        /// Bytes a second, over the last few seconds.
        var speed: Int64 = 0
        fileprivate var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []

        var isFinished: Bool {
            if case .finished = status.state { return true }
            return false
        }
    }

    private(set) var jobs: [Job] = []
    /// The songs on this phone, downloaded now or before, by folder and file name; nil until
    /// they've been read.
    private(set) var onPhone: [DownloadedSong]?
    private var onPhoneReads = 0
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private unowned let model: AppModel

    /// Where songs are saved: in the app's Documents, which the Files app shows.
    let directory = URL.documentsDirectory.appending(path: "Clementine", directoryHint: .isDirectory)

    init(model: AppModel) {
        self.model = model
    }

    var active: [Job] { jobs.filter { !$0.isFinished } }
    var finished: [Job] { jobs.filter(\.isFinished).reversed() }

    /// Nothing downloading, downloaded, or on this phone, once the songs on it have been read.
    var isEmpty: Bool { jobs.isEmpty && onPhone?.isEmpty == true }

    /// Free space on the phone.
    var freeSpace: Int64? {
        LibraryStore.freeSpace(at: directory.appending(path: "x"))
    }

    // MARK: Starting downloads

    /// Downloads the current song, its album, or the active playlist.
    func downloadCurrent(_ item: DownloadItem) {
        guard let song = model.session.song else {
            model.toasts.show("No song playing")
            return
        }
        guard song.isLocal else {
            model.toasts.show("Streams can't be downloaded")
            return
        }
        switch item {
        case .aplaylist:
            if let playlist = model.session.activePlaylist {
                download(playlist: playlist)
            }
        case .itemAlbum:
            start(.album, Messages.downloadSongs(.itemAlbum), playlistName: nil)
        default:
            start(.song, Messages.downloadSongs(.currentItem), playlistName: nil)
        }
    }

    func download(playlist: Playlist) {
        start(.playlist(playlist.name), Messages.downloadSongs(.aplaylist, playlistID: playlist.id), playlistName: playlist.name)
    }

    func download(urls: [String]) {
        guard !urls.isEmpty else { return }
        start(.songs, Messages.downloadSongs(.urls, urls: urls), playlistName: nil)
    }

    /// Downloads the songs [items] of the library are or group.
    func download(libraryItems items: [BrowseItem]) async {
        download(urls: await model.library.songURLs(of: items))
    }

    private func start(_ kind: Kind, _ request: RemoteMessage, playlistName: String?) {
        guard let endpoint = model.session.endpoint else { return }
        let id = nextID
        nextID += 1
        var job = Job(id: id, kind: kind)
        if model.settings.wifiOnly, !model.network.isOnWiFi {
            job.status.state = .finished(.onlyOnWiFi)
            jobs.append(job)
            model.toasts.show(DownloadFailure.onlyOnWiFi.message)
            return
        }
        jobs.append(job)
        model.toasts.show("Download started")
        requestNotifications()

        let downloader = SongDownloader(
            endpoint: endpoint, authCode: model.session.authCode, request: request,
            playlistName: playlistName, options: DownloadOptions(directory: directory, settings: model.settings))
        let background = UIApplication.shared.beginBackgroundTask(withName: "Download") { [weak self] in
            self?.cancel(id)
        }
        tasks[id] = Task {
            let (updates, continuation) = AsyncStream.makeStream(of: DownloadStatus.self, bufferingPolicy: .bufferingNewest(1))
            let shown = Task {
                for await status in updates {
                    update(id, status)
                }
            }
            let status = await downloader.run { continuation.yield($0) }
            continuation.finish()
            await shown.value
            update(id, status)
            tasks[id] = nil
            readOnPhone()
            finished(status)
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    private func update(_ id: Int, _ status: DownloadStatus) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        job.status = status
        let now = ContinuousClock.now
        job.samples.append((now, status.bytes))
        job.samples.removeAll { now - $0.time > .seconds(3) }
        if let first = job.samples.first, let last = job.samples.last, last.time > first.time {
            let seconds = (last.time - first.time).timeInterval
            job.speed = Int64(Double(last.bytes - first.bytes) / max(seconds, 0.001))
        }
        jobs[index] = job
    }

    // MARK: Managing downloads

    func cancel(_ id: Int) {
        tasks[id]?.cancel()
    }

    /// Takes a finished download off the list; its songs stay on the phone.
    func remove(_ id: Int) {
        jobs.removeAll { $0.id == id && $0.isFinished }
    }

    /// Reads the songs on this phone again: when Downloads shows, and each time a download
    /// finishes.
    func readOnPhone() {
        onPhoneReads += 1
        let read = onPhoneReads
        let directory = directory
        Task {
            let songs = await Task.detached { DownloadedSong.saved(in: directory) }.value
            // An earlier read that finishes later is out of date.
            if read == onPhoneReads {
                onPhone = songs
            }
        }
    }

    private func requestNotifications() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        }
    }

    /// Says a download finished, if the app isn't in front to show it.
    private func finished(_ status: DownloadStatus) {
        guard UIApplication.shared.applicationState != .active, case .finished(let failure) = status.state else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Download finished")
        content.body = String(localized: failure?.message ?? "Download complete")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension DownloadsModel.Job {
    /// What's being downloaded.
    var title: String {
        let status = status
        switch status.state {
        case .starting:
            return String(localized: "Starting download")
        case .transcoding:
            return String(localized: "Transcoding files")
        case .downloading, .finished:
            switch kind {
            case .playlist(let name): return String(localized: "Playlist \(name)")
            case .album: return String(localized: "Album \(status.album)")
            case .song: return String(localized: "Song \(status.title)")
            case .songs: return String(localized: "Songs")
            }
        }
    }

    /// How it's going.
    var subtitle: String {
        let status = status
        switch status.state {
        case .starting:
            return String(localized: "Connecting…")
        case .transcoding(let done, let total):
            return String(localized: "(\(done)/\(total)) Please wait")
        case .downloading:
            return "(\(status.fileNumber)/\(status.fileCount)) \(status.artist) - \(status.title)"
        case .finished(let failure):
            let result = String(localized: failure?.message ?? "Download complete")
            return status.fileCount > 0 ? "(\(status.fileNumber)/\(status.fileCount)) \(result)" : result
        }
    }

    /// Bytes so far, of the total, and the speed while downloading.
    var sizes: String {
        var text = "\(formatBytes(status.bytes)) / \(formatBytes(status.totalBytes))"
        if !isFinished {
            text += " (\(formatBytes(speed))/s)"
        }
        return text
    }

    var systemImage: String {
        switch kind {
        case .song, .songs: "music.note"
        case .album: "opticaldisc"
        case .playlist: "list.bullet"
        }
    }
}
