import Foundation

/// A song a search found, to put in a section.
struct SearchCandidate {
    /// The song, at the songs' level of browsing by album artist, album and title, after any
    /// levels above (such as where it came from).
    var item: BrowseItem
    /// The song's own artist; the album artist is in [item]'s selection.
    var artist: String
    /// Whether it's a file, not a stream.
    var isLocal = true
}

/// A search's results, in sections by what matched, as music apps show them: songs whose titles
/// matched, artists and albums whose names did, radio stations, and the rest. Both Clementine's
/// global search and the library on the phone are shown this way.
public struct SearchSections: Sendable, Equatable {
    /// The best match, if one matched well: also the first of its section.
    public var top: BrowseItem?
    /// Songs whose titles matched, or whose title, artist and album did between them.
    public var songs: [BrowseItem] = []
    public var artists: [BrowseItem] = []
    /// Albums whose names matched, or whose name and artist did between them.
    public var albums: [BrowseItem] = []
    /// Results from internet services that aren't songs: radio streams.
    public var stations: [BrowseItem] = []
    /// Songs that matched some other way, such as by genre or composer.
    public var others: [BrowseItem] = []

    public init() {}

    public var isEmpty: Bool {
        songs.isEmpty && artists.isEmpty && albums.isEmpty && stations.isEmpty && others.isEmpty
    }

    /// [songs] found by searching for [query], in sections. Artists and albums are items a level
    /// and two levels above the songs.
    init(query: String, songs candidates: [SearchCandidate]) {
        let matcher = SearchMatcher(query)
        var songs: [(BrowseItem, MatchQuality)] = []
        var stations: [(BrowseItem, MatchQuality)] = []
        var others: [BrowseItem] = []
        var artists: [[String]: Group] = [:]
        var albums: [[String]: Group] = [:]

        for candidate in candidates {
            let item = candidate.item
            let groupArtist = item.selection[item.level - 2]
            let title = SearchMatcher.Field(item.value)
            let artist = SearchMatcher.Field(candidate.artist)
            let group = SearchMatcher.Field(groupArtist)
            let album = SearchMatcher.Field(item.album)

            // Internet radio: a stream has a name but no artist or album.
            if !candidate.isLocal, artist.isEmpty, group.isEmpty, album.isEmpty {
                stations.append((item, matcher.quality(title) ?? .spread))
                continue
            }

            var grouped = false
            if let quality = matcher.quality(group) {
                let artistItem = Group(item, level: item.level - 2, kind: .artist)
                artists[artistItem.item.selection, default: artistItem].add(quality: quality, below: item.album)
                grouped = true
            }
            if !album.isEmpty, matcher.matches(across: [album, group]) {
                let albumItem = Group(item, level: item.level - 1, kind: .album)
                albums[albumItem.item.selection, default: albumItem]
                    .add(quality: matcher.quality(album) ?? .spread, below: item.url)
                grouped = true
            }
            if let quality = matcher.quality(title) {
                songs.append((item, quality))
            } else if matcher.matches(across: [title, artist, group, album]), matcher.touches(title) || !grouped {
                songs.append((item, .spread))
            } else if !grouped {
                others.append(item)
            }
        }

        let ranked = [
            Self.ranked(artists.values.map { ($0.item, $0.quality) }), Self.ranked(albums.values.map { ($0.item, $0.quality) }),
            Self.ranked(songs), Self.ranked(stations),
        ]
        self.artists = ranked[0].map(\.0)
        self.albums = ranked[1].map(\.0)
        self.songs = ranked[2].map(\.0)
        self.stations = ranked[3].map(\.0)
        self.others = others.sorted(by: Self.inOrder)
        // The best match of all, if it matched well: artists first, then albums, songs and stations
        // when as good.
        let firsts = ranked.compactMap(\.first)
        if let best = firsts.map(\.1).max(), best >= .words {
            top = firsts.first { $0.1 == best }?.0
        }
    }

    /// An artist or album of the results, and how well it matched.
    private struct Group {
        var item: BrowseItem
        var quality = MatchQuality.spread
        private var below = Set<String>()

        /// The group at [level] above [song].
        init(_ song: BrowseItem, level: Int, kind: ItemKind) {
            let artistLevel = song.level - 2
            item = BrowseItem(
                level: level, selection: Array(song.selection[0...level]), kind: kind, url: song.url,
                artist: song.selection[artistLevel], album: level > artistLevel ? song.album : "", itemCount: 0)
        }

        mutating func add(quality: MatchQuality, below value: String) {
            self.quality = max(self.quality, quality)
            below.insert(value)
            item.itemCount = below.count
        }
    }

    /// Items by how well they matched, best first, then by name.
    private static func ranked(_ items: [(BrowseItem, MatchQuality)]) -> [(BrowseItem, MatchQuality)] {
        items.sorted { first, second in
            first.1 != second.1 ? first.1 > second.1 : inOrder(first.0, second.0)
        }
    }

    private static func inOrder(_ first: BrowseItem, _ second: BrowseItem) -> Bool {
        for (a, b) in [(first.value, second.value), (first.artist, second.artist), (first.album, second.album)] {
            let order = a.localizedStandardCompare(b)
            if order != .orderedSame {
                return order == .orderedAscending
            }
        }
        return false
    }
}
