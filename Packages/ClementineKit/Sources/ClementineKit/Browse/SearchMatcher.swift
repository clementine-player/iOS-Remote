import Foundation

/// How well a search matched a field, weakest first.
public enum MatchQuality: Int, Comparable, Sendable {
    /// The words matched between this field and others.
    case spread = 1
    /// Every word starts a word of the field.
    case words
    /// The field starts with the search.
    case prefix
    /// The field is the search.
    case exact

    public static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A search's words, matched as Clementine's library search matches them: each word must start a
/// word of some field. Clementine sends the songs it found but not why they matched, so the app
/// works that out. It ignores accents as well as case, so it may explain more than Clementine
/// matched, never less.
struct SearchMatcher {
    /// A field's text, split into words for matching.
    struct Field {
        let words: [String]

        init(_ text: String) {
            words = SearchMatcher.words(of: text)
        }

        var isEmpty: Bool { words.isEmpty }

        func contains(_ word: String) -> Bool {
            words.contains { $0.hasPrefix(word) }
        }
    }

    let words: [String]
    private let phrase: String

    init(_ query: String) {
        words = query.split(whereSeparator: \.isWhitespace).flatMap { token in
            // Clementine takes "artist:name" to search only artists; the field name isn't a word.
            var token = Substring(token)
            if let colon = token.firstIndex(of: ":"), token[..<colon].allSatisfy(\.isLetter) {
                token = token[token.index(after: colon)...]
            }
            return Self.words(of: String(token))
        }
        phrase = words.joined(separator: " ")
    }

    /// [text]'s words, folded: split where SQLite's full-text index splits them.
    static func words(of text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// How well [field] alone matches, or nil if it doesn't have every word.
    func quality(_ field: Field) -> MatchQuality? {
        guard !words.isEmpty, words.allSatisfy(field.contains) else { return nil }
        let text = field.words.joined(separator: " ")
        if text == phrase {
            return .exact
        }
        return text.hasPrefix(phrase) ? .prefix : .words
    }

    /// Whether each word is in one of [fields].
    func matches(across fields: [Field]) -> Bool {
        !words.isEmpty && words.allSatisfy { word in fields.contains { $0.contains(word) } }
    }

    /// Whether any word is in [field].
    func touches(_ field: Field) -> Bool {
        words.contains(where: field.contains)
    }
}
