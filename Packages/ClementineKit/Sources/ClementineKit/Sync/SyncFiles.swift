import Foundation

/// Where synced songs go in the synced songs' folder: `<artist>/<album>/<track> <title>`, as in the
/// Android client.
enum SyncFiles {
    private static let maxName = 100

    /// The folder `song` goes in, relative to the synced songs' folder, ending in "/".
    static func relativeDirectory(_ song: SongMetadata) -> String {
        let artist = song.albumartist.trimmingCharacters(in: .whitespaces).isEmpty ? song.artist : song.albumartist
        return part(artist, otherwise: "Unknown artist") + "/" + part(song.album, otherwise: "Unknown album") + "/"
    }

    static func fileName(_ song: SongMetadata, mimeType: String) -> String {
        let title = part(song.title, otherwise: "Untitled")
        let name = song.track > 0 ? (song.track < 10 ? "0" : "") + String(song.track) + " " + title : title
        return name + "." + fileExtension(mimeType)
    }

    /// `name` in `directory` (relative to `folder`), or with a number added if another file has
    /// it already. `own` is the path of the song being replaced, which may keep its name.
    static func freeName(in folder: URL, directory: String, name: String, own: String?) -> String {
        let dot = name.lastIndex(of: ".") ?? name.endIndex
        let base = name[..<dot]
        let suffix = name[dot...]
        var candidate = name
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: directory + candidate).path),
              directory + candidate != own {
            candidate = "\(base) (\(number))\(suffix)"
            number += 1
        }
        return candidate
    }

    static func fileExtension(_ mimeType: String) -> String {
        let parts = mimeType.lowercased().split(separator: ";", maxSplits: 1)
        let type = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let codecs = parts.count > 1
            ? parts[1].components(separatedBy: "codecs=").dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
            : ""
        switch type {
        case "audio/mpeg": return "mp3"
        case "audio/flac": return "flac"
        case "audio/mp4": return "m4a"
        case "audio/aac": return "aac"
        case "audio/wav": return "wav"
        case "audio/aiff": return "aiff"
        case "audio/ogg": return codecs == "opus" ? "opus" : "ogg"
        default: return "audio"
        }
    }

    /// `text` with the characters file systems don't take in a name replaced, or `otherwise` if
    /// that leaves nothing.
    private static func part(_ text: String, otherwise: String) -> String {
        let unsafe = Set("\\/:*?\"<>|".unicodeScalars)
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(unsafe.contains(scalar) || scalar.value < 0x20 ? "_" : scalar)
        }
        let safe = String(String(scalars)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .prefix(maxName))
        return safe.isEmpty ? otherwise : safe
    }
}
