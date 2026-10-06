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
    /// Their tags aren't read, as that means opening every file: each is named after its file,
    /// with the folders it's in (its artist and album) as its second line.
    public static func saved(in directory: URL) -> [DownloadedSong] {
        var found: [(folders: [String], name: String, file: URL)] = []
        func add(_ folder: URL, _ folders: [String]) {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for item in items {
                let name = item.lastPathComponent
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    add(item, folders + [name])
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
                    artist: song.folders.joined(separator: " / "),
                    album: "",
                    file: song.file)
            }
    }

    /// Whether a file is of a kind Clementine plays, by its extension.
    static func isAudio(_ name: String) -> Bool {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(fileExtension)
    }
}
