import Foundation

/// A review score shown as a badge next to the year and runtime.
public struct Rating: Hashable, Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case rottenTomatoes, rottenTomatoesAudience, imdb, metacritic, letterboxd, tmdb
    }

    public var source: Source
    /// Display text without the source name: "93%", "7.8", "74".
    public var value: String
    /// 0...100, for picking the fresh/rotten artwork.
    public var score: Double

    /// Rotten Tomatoes' own threshold: 60% and up is "fresh".
    public var isFresh: Bool { score >= 60 }
}

/// Some catalog add-ons put ratings into the synopsis as text ("🍅 Rotten Tomatoes: 93% | IMDb 7.8").
/// This lifts them out into structured ratings and returns the synopsis without them, so the ratings
/// render as badges on the metadata line instead of cluttering the description.
public enum RatingsExtractor {
    public struct Result: Equatable, Sendable {
        public var ratings: [Rating]
        public var description: String?
    }

    private struct Pattern {
        let source: Rating.Source
        let regex: NSRegularExpression
        let percent: Bool
        let outOf: Double
    }

    private static let number = #"(\d{1,3}(?:[.,]\d)?)"#

    private static let patterns: [Pattern] = {
        func make(_ source: Rating.Source, _ pattern: String, percent: Bool, outOf: Double = 100) -> Pattern {
            Pattern(source: source, regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                    percent: percent, outOf: outOf)
        }
        return [
            // Audience score first so "Rotten Tomatoes Audience 88%" is not read as the Tomatometer.
            make(.rottenTomatoesAudience,
                 #"(?:🍿\s*(?:audience(?:\s*score)?|popcornmeter)?|popcornmeter|(?:rotten\s*tomatoes|rt)\s*audience(?:\s*score)?)\s*[:\-–]?\s*"# + number + #"\s*%"#,
                 percent: true),
            make(.rottenTomatoes,
                 #"(?:🍅\s*(?:rotten\s*tomatoes|tomatometer|rt)?|rotten\s*tomatoes|tomatometer|\brt\b)\s*(?:score)?\s*[:\-–]?\s*"# + number + #"\s*%"#,
                 percent: true),
            make(.imdb, #"(?:⭐\s*)?\bimdb\b\s*(?:rating)?\s*[:\-–]?\s*"# + number + #"(?:\s*/\s*10)?"#,
                 percent: false, outOf: 10),
            make(.metacritic, #"\b(?:metacritic|metascore|mc)\b\s*[:\-–]?\s*"# + number + #"(?:\s*/\s*100)?"#,
                 percent: false, outOf: 100),
            make(.letterboxd, #"\bletterboxd\b\s*[:\-–]?\s*"# + number + #"(?:\s*/\s*5)?"#,
                 percent: false, outOf: 5),
            make(.tmdb, #"\btmdb\b\s*[:\-–]?\s*"# + number + #"(?:\s*/\s*10)?"#,
                 percent: false, outOf: 10),
        ]
    }()

    public static func extract(from description: String?, imdbRating: String? = nil) -> Result {
        var ratings: [Rating] = []
        var text = description ?? ""
        for pattern in patterns {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.regex.firstMatch(in: text, range: range),
                  let valueRange = Range(match.range(at: 1), in: text),
                  let fullRange = Range(match.range, in: text) else { continue }
            let raw = text[valueRange].replacingOccurrences(of: ",", with: ".")
            guard let value = Double(raw), value >= 0, value <= pattern.outOf else { continue }
            if !ratings.contains(where: { $0.source == pattern.source }) {
                let display = pattern.percent ? "\(Int(value))%" : raw
                ratings.append(Rating(source: pattern.source, value: display, score: value / pattern.outOf * 100))
            }
            text.removeSubrange(fullRange)
        }
        if !ratings.contains(where: { $0.source == .imdb }), let imdbRating, let value = Double(imdbRating), value > 0 {
            ratings.append(Rating(source: .imdb, value: imdbRating, score: value * 10))
        }
        ratings.sort { order($0.source) < order($1.source) }
        return Result(ratings: ratings, description: clean(text, original: description))
    }

    private static func order(_ source: Rating.Source) -> Int {
        Rating.Source.allCases.firstIndex(of: source) ?? 0
    }

    /// Remove the separators and empty lines left behind by the ratings that were lifted out.
    private static func clean(_ text: String, original: String?) -> String? {
        guard original != nil else { return nil }
        let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
            var line = line
            // Collapse leftover separators: "|  |", " • • ", leading/trailing dividers.
            line = line.replacingOccurrences(of: #"(\s*[|•·/,]\s*){2,}"#, with: " · ", options: .regularExpression)
            // A separator left dangling before punctuation or the end: "goes wrong. , ." -> "goes wrong."
            line = line.replacingOccurrences(of: #"\s*([|•·/,]\s*)+(?=[.!?]|$)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"([.!?])(\s*[.!?])+"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t|•·/,-–:"))
            let bare = line.replacingOccurrences(of: #"(?i)\b(ratings?|scores?|reviews?)\b"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters).union(.symbols))
            return bare.isEmpty ? nil : line
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

public extension MetaPreview {
    var ratingsAndSynopsis: RatingsExtractor.Result { RatingsExtractor.extract(from: description, imdbRating: imdbRating) }
}

public extension MetaDetail {
    var ratingsAndSynopsis: RatingsExtractor.Result { RatingsExtractor.extract(from: description, imdbRating: imdbRating) }
}
