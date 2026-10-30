import Foundation

extension DownloadedSong {
    /// The kinds of file Clementine plays, and so can send, by their extensions.
    static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "ape", "flac", "m4a", "mp3", "mp4", "mpc", "oga", "ogg",
        "opus", "spc", "spx", "tta", "vgm", "wav", "wma", "wv",
    ]

    /// The songs saved under [directory], whenever they were downloaded, by folder and file name:
    /// with the folder settings' defaults, by artist and album, then by file name.
    ///
    /// Their tags aren't read, as that means opening every file: each is named after its file, and
    /// its artist and album after the folders it's in ("Artist/Album/"). The songs in [skipping],
    /// such as the synced songs' folder, are left out.
    public static func saved(in directory: URL, skipping: URL? = nil) -> [DownloadedSong] {
        let skipped = skipping?.resolvingSymlinksInPath().pathComponents
        var found: [(folders: [String], name: String, file: URL)] = []
        func add(_ folder: URL, _ folders: [String]) {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for item in items {
                let name = item.lastPathComponent
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if item.resolvingSymlinksInPath().pathComponents != skipped {
                        add(item, folders + [name])
                    }
                } else if isAudio(name) {
                    found.append((folders, name, item))
                }
            }
        }
        add(directory, [])
        return found
            .sorted { first, second in
                let folders = first.folders.joined(separator: "/").localizedStandardCompare(second.folders.joined(separator: "/"))
                if folders != .orderedSame {
                    return folders == .orderedAscending
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
            .map { song in
                DownloadedSong(
                    title: (song.name as NSString).deletingPathExtension,
                    artist: song.folders.first ?? "",
                    album: song.folders.count > 1 ? song.folders[1] : "",
                    file: song.file)
            }
    }

    /// The albums [songs] are on, by title, with their songs in the order given. Songs on no album
    /// aren't on any.
    public static func albums(of songs: [DownloadedSong]) -> [PhoneAlbum] {
        var albums: [PhoneAlbum] = []
        var indexes: [PhoneAlbum.ID: Int] = [:]
        for song in songs where !song.album.isEmpty {
            let id = PhoneAlbum.ID(title: song.album, artist: song.artist)
            if let index = indexes[id] {
                albums[index].songs.append(song)
            } else {
                indexes[id] = albums.count
                albums.append(PhoneAlbum(id: id, songs: [song]))
            }
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The artists of [songs], by name.
    public static func artists(of songs: [DownloadedSong]) -> [String] {
        Set(songs.map(\.artist).filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Whether a file is of a kind Clementine plays, by its extension.
    static func isAudio(_ name: String) -> Bool {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(fileExtension)
    }
}


/// An album on this phone: its songs there, with its title and artist.
public struct PhoneAlbum: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        public var title: String
        public var artist: String

        public init(title: String, artist: String) {
            self.title = title
            self.artist = artist
        }
    }

    public var id: ID
    public var songs: [DownloadedSong]

    public var title: String { id.title }
    public var artist: String { id.artist }
}
