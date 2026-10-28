import Foundation

/// On-device search: every word of the query must start a word the photo is known by: text and things Vision found
/// in it, its place, its kind, or its date ("june", "2023", "june 2023").
public enum SearchMatcher {
    /// Lowercased words without accents, so "Café" finds "cafe".
    public static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The words a date is found by: the year and the month's full and short English names.
    public static func dateWords(_ date: Date?, calendar: Calendar = .current) -> [String] {
        guard let date else { return [] }
        let c = calendar.dateComponents([.year, .month], from: date)
        guard let year = c.year, let month = c.month, (1...12).contains(month) else { return [] }
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        return [String(year), names[month - 1]]
    }

    /// Whether every query word starts one of `known` (already passed through `words`).
    public static func matches(query: [String], known: [String]) -> Bool {
        guard !query.isEmpty else { return false }
        return query.allSatisfy { term in known.contains { $0.hasPrefix(term) } }
    }

    /// The words Vision found, cleaned for storage: classification identifiers use underscores ("sea_lion"), and long
    /// text is cut so one page of a scanned document doesn't make a huge row.
    public static func storedWords(text: [String], things: [String], limit: Int = 300) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for w in words((things.map { $0.replacingOccurrences(of: "_", with: " ") } + text).joined(separator: " ")) where w.count > 1 {
            if seen.insert(w).inserted { out.append(w) }
            if out.count == limit { break }
        }
        return out.joined(separator: " ")
    }

    /// The ~1 km grid cell a location falls in; place names are looked up once per cell.
    public static func placeCell(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f,%.2f", (latitude * 100).rounded() / 100, (longitude * 100).rounded() / 100)
    }
}

/// An inverted index: every known word once, sorted, with the entries it belongs to. A query word is found by binary
/// search for the words it starts (like SQLite FTS prefix queries), so typing stays instant in a big library instead
/// of checking every photo's words.
public struct SearchIndex: Sendable {
    private let words: [String]
    private let postings: [[Int32]]
    /// Entry ids in timeline order; results come back in this order.
    private let ids: [String]

    public static let empty = SearchIndex(entries: [])

    /// `entries`: (id, its words already passed through `SearchMatcher.words`), in timeline order.
    public init(entries: [(id: String, words: [String])]) {
        var map: [String: [Int32]] = [:]
        for (i, e) in entries.enumerated() {
            for w in Set(e.words) { map[w, default: []].append(Int32(i)) }
        }
        let sorted = map.keys.sorted()
        words = sorted
        postings = sorted.map { map[$0]! }
        ids = entries.map(\.id)
    }

    public var count: Int { ids.count }

    /// Ids of the entries where every query word starts one of their words, in timeline order.
    public func search(_ query: String) -> [String] {
        let terms = SearchMatcher.words(query)
        guard !terms.isEmpty else { return [] }
        var result: Set<Int32>?
        // The rarest word first keeps the intersections small.
        for term in terms.map(matches).sorted(by: { $0.count < $1.count }) {
            result = result.map { $0.intersection(term) } ?? term
            if result?.isEmpty == true { return [] }
        }
        return (result ?? []).sorted().map { ids[Int($0)] }
    }

    /// Every entry with a word starting with `prefix`.
    private func matches(_ prefix: String) -> Set<Int32> {
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        var out = Set<Int32>()
        var i = lo
        while i < words.count, words[i].hasPrefix(prefix) {
            out.formUnion(postings[i])
            i += 1
        }
        return out
    }
}
