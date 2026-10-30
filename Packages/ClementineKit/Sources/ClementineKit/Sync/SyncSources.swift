import Foundation

/// The sources a rule can keep from Clementine's library, as Clementine names them in
/// SyncSource.source_id: "library/album/<album artist>/<album>", "library/artist/<artist>" and
/// "playlist/<id>", each part percent-encoded as Clementine encodes it (QUrl::toPercentEncoding).
public enum SyncSources {
    public static func album(albumArtist: String, album: String) -> String {
        "library/album/\(encode(albumArtist))/\(encode(album))"
    }

    public static func artist(_ artist: String) -> String {
        "library/artist/\(encode(artist))"
    }

    public static func playlist(_ id: Int32) -> String {
        "playlist/\(id)"
    }

    /// A rule keeping everything an album has, now and later.
    public static func albumRule(serverID: String, albumArtist: String, album: String) -> SyncRule {
        SyncRule(
            serverID: serverID, sourceID: self.album(albumArtist: albumArtist, album: album), title: album,
            kind: Pb_Remote_SyncSourceKind.album, refreshPolicy: .never)
    }

    /// A rule keeping every song by an artist.
    public static func artistRule(serverID: String, artist: String) -> SyncRule {
        SyncRule(
            serverID: serverID, sourceID: self.artist(artist), title: artist,
            kind: Pb_Remote_SyncSourceKind.artist, refreshPolicy: .never)
    }

    /// The library's fields whose items can be kept: an artist's songs, or an album.
    public static let keepableFields: Set<String> = ["artist", "album"]

    /// As QUrl::toPercentEncoding: every UTF-8 byte but letters, digits and -._~ as %XX.
    static func encode(_ part: String) -> String {
        var encoded = ""
        for byte in part.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                encoded.append(Character(Unicode.Scalar(byte)))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }
}
