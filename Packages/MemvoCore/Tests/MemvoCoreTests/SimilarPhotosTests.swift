import Foundation
import Testing
import MemvoCore

@Suite struct SimilarPhotosTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func c(_ id: String, _ seconds: Double, pixels: Int = 100, favorite: Bool = false) -> SimilarPhotos.Candidate {
        .init(id: id, date: t0.addingTimeInterval(seconds), pixels: pixels, favorite: favorite)
    }

    @Test func runsSplitOnGapsAndDropSingles() {
        let runs = SimilarPhotos.runs([c("b", 30), c("a", 0), c("c", 200), c("d", 230), c("e", 1000)])
        #expect(runs.map { $0.map(\.id) } == [["a", "b"], ["c", "d"]])
    }

    @Test func longRunsAreSplit() {
        let many = (0..<(SimilarPhotos.maxRun + 5)).map { c("p\($0)", Double($0)) }
        let runs = SimilarPhotos.runs(many)
        #expect(runs.count == 2)
        #expect(runs[0].count == SimilarPhotos.maxRun)
        #expect(runs[1].count == 5)
    }

    @Test func groupsFollowCloseDistancesTransitively() {
        // a~b, b~c are close; d is far from everything; e can't be compared.
        let run = [c("a", 0), c("b", 1), c("c", 2), c("d", 3), c("e", 4)]
        let close: Set<String> = ["ab", "bc"]
        let groups = SimilarPhotos.groups(in: run) { x, y in
            if x.id == "e" || y.id == "e" { return nil }
            return close.contains(x.id + y.id) ? 0.1 : 0.9
        }
        #expect(groups.map { $0.map(\.id) } == [["a", "b", "c"]])
    }

    @Test func suggestsFavouriteThenLargestThenFirst() {
        #expect(SimilarPhotos.best([c("a", 0, pixels: 50), c("b", 1, pixels: 10, favorite: true)])?.id == "b")
        #expect(SimilarPhotos.best([c("a", 0, pixels: 50), c("b", 1, pixels: 90)])?.id == "b")
        #expect(SimilarPhotos.best([c("a", 0), c("b", 1)])?.id == "a")
    }
}
