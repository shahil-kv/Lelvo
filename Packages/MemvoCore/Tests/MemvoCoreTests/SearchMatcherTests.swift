import Foundation
import Testing
import MemvoCore

@Suite struct SearchMatcherTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func everyQueryWordMustStartAKnownWord() {
        let known = SearchMatcher.words("Beach sunset Kochi Kerala") + ["2023", "june"]
        #expect(SearchMatcher.matches(query: SearchMatcher.words("sun"), known: known))
        #expect(SearchMatcher.matches(query: SearchMatcher.words("June 2023 beach"), known: known))
        #expect(!SearchMatcher.matches(query: SearchMatcher.words("beach dog"), known: known))
        #expect(!SearchMatcher.matches(query: SearchMatcher.words("each"), known: known))
        #expect(!SearchMatcher.matches(query: [], known: known))
    }

    @Test func accentsAndCaseDontMatter() {
        #expect(SearchMatcher.matches(query: SearchMatcher.words("CAFE"), known: SearchMatcher.words("Café de Flore")))
    }

    @Test func datesAreFoundByYearAndMonth() {
        let date = Date(timeIntervalSince1970: 1_686_000_000) // 5 June 2023
        #expect(SearchMatcher.dateWords(date, calendar: utc) == ["2023", "june"])
        #expect(SearchMatcher.dateWords(nil).isEmpty)
    }

    @Test func storedWordsAreCleanUniqueAndCapped() {
        let stored = SearchMatcher.storedWords(text: ["Hello hello WORLD", "a"], things: ["sea_lion", "outdoor"])
        #expect(stored == "sea lion outdoor hello world")
        #expect(SearchMatcher.storedWords(text: (0..<500).map { "w\($0)" }, things: [], limit: 10).split(separator: " ").count == 10)
    }

    @Test func nearbyPlacesShareACell() {
        #expect(SearchMatcher.placeCell(latitude: 9.9312, longitude: 76.2673) == SearchMatcher.placeCell(latitude: 9.9298, longitude: 76.2701))
        #expect(SearchMatcher.placeCell(latitude: 9.93, longitude: 76.26) != SearchMatcher.placeCell(latitude: 9.96, longitude: 76.26))
    }
}

@Suite struct SearchIndexTests {
    let index = SearchIndex(entries: [
        (id: "a", words: SearchMatcher.words("beach sunset Kochi 2023 june")),
        (id: "b", words: SearchMatcher.words("dog beach Goa 2024")),
        (id: "c", words: SearchMatcher.words("receipt cafe Kochi 2023")),
    ])

    @Test func findsByPrefixInTimelineOrder() {
        #expect(index.search("bea") == ["a", "b"])
        #expect(index.search("Kochi 2023") == ["a", "c"])
        #expect(index.search("kochi beach") == ["a"])
        #expect(index.search("café") == ["c"])
    }

    @Test func missingWordsFindNothing() {
        #expect(index.search("cat").isEmpty)
        #expect(index.search("beach cat").isEmpty)
        #expect(index.search("  ").isEmpty)
        #expect(SearchIndex.empty.search("beach").isEmpty)
    }

    /// The same answers as checking every entry's words.
    @Test func agreesWithMatcher() {
        let entries = (0..<300).map { i in (id: "e\(i)", words: SearchMatcher.words("w\(i % 7) x\(i % 11) year\(2000 + i % 5)")) }
        let index = SearchIndex(entries: entries)
        for q in ["w3", "x1 w2", "year2003", "w", "x10 year2001"] {
            let slow = entries.filter { SearchMatcher.matches(query: SearchMatcher.words(q), known: $0.words) }.map(\.id)
            #expect(index.search(q) == slow, "\(q)")
        }
    }
}
