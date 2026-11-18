import Foundation
import Testing
import LelvoCore

@Suite struct ArrayChangesTests {
    @Test func removesByOldIndexAndInsertsByNewIndex() {
        // [a b c d] → remove b, d → [a c] → insert x at 0 and y at 2 → [x a y c]
        let out = ArrayChanges.apply(to: ["a", "b", "c", "d"], removed: IndexSet([1, 3]),
                                     inserted: [(2, "y"), (0, "x")], changed: [])
        #expect(out == ["x", "a", "y", "c"])
    }

    @Test func changedIndexesReferToTheNewArray() {
        let out = ArrayChanges.apply(to: ["a", "b", "c"], removed: IndexSet([0]), inserted: [], changed: [(1, "C")])
        #expect(out == ["b", "C"])
    }

    @Test func emptyChangeKeepsTheArray() {
        #expect(ArrayChanges.apply(to: [1, 2, 3], removed: [], inserted: [], changed: []) == [1, 2, 3])
    }

    @Test func outOfRangeChangesAskForAFullReload() {
        #expect(ArrayChanges.apply(to: [1, 2], removed: IndexSet([5]), inserted: [], changed: []) == nil)
        #expect(ArrayChanges.apply(to: [1, 2], removed: [], inserted: [(4, 9)], changed: []) == nil)
        #expect(ArrayChanges.apply(to: [1, 2], removed: [], inserted: [], changed: [(2, 9)]) == nil)
    }
}

@Suite struct StoreChangeTests {
    func item(_ name: String) -> MediaItem {
        MediaItem(localIdentifier: nil, sha256: name, filename: name, kind: .photo, creationDate: Date(), fileSize: 1, status: .backedUp)
    }

    /// The changed ids of the next `didChange` from `store` (posted asynchronously on the main queue, so the stream is
    /// listening before it arrives).
    @MainActor func nextChange(of store: LibraryStore, _ body: () throws -> Void) async throws -> Set<String>?? {
        let changes = NotificationCenter.default.notifications(named: LibraryStore.didChange, object: store)
        try body()
        for await note in changes { return .some(LibraryStore.changedIds(note)) }
        return nil
    }

    @Test @MainActor func upsertReportsTheChangedIds() async throws {
        let store = try LibraryStore(url: nil)
        let a = item("a"), b = item("b")
        let ids = try await nextChange(of: store) { try store.upsert([a, b]) }
        #expect(ids == .some([a.id, b.id]))
    }

    @Test @MainActor func deleteReportsItsIdAndDeleteAllReportsEverything() async throws {
        let store = try LibraryStore(url: nil)
        let a = item("a")
        _ = try await nextChange(of: store) { try store.upsert(a) }
        let deleted = try await nextChange(of: store) { try store.delete(id: a.id) }
        #expect(deleted == .some([a.id]))
        let cleared = try await nextChange(of: store) { try store.deleteAll() }
        #expect(cleared == .some(nil))
    }

    @Test func itemsByIdsReturnsOnlyExistingItems() throws {
        let store = try LibraryStore(url: nil)
        let items = (0..<1200).map { item("i\($0)") }
        try store.upsert(items)
        let wanted = items.map(\.id).enumerated().filter { $0.offset % 2 == 0 }.map(\.element) + ["missing"]
        let found = try store.items(ids: wanted)
        #expect(Set(found.map(\.id)) == Set(wanted.dropLast()))
        #expect(try store.items(ids: [String]()).isEmpty)
    }
}

@Suite struct OrderedItemsTests {
    func item(_ id: String, minute: Int?) -> MediaItem {
        var m = MediaItem(localIdentifier: nil, sha256: id, filename: id, kind: .photo,
                          creationDate: minute.map { Date(timeIntervalSince1970: Double($0 * 60)) }, fileSize: 1, status: .backedUp)
        m.id = id
        return m
    }

    @Test func startsNewestFirstWithUndatedLastAndTiesById() {
        let ordered = OrderedItems([item("b", minute: 5), item("x", minute: nil), item("a", minute: 5), item("c", minute: 9)])
        #expect(ordered.items.map(\.id) == ["c", "a", "b", "x"])
    }

    @Test func updateMovesChangedItemsAndDropsDeletedOnes() {
        var ordered = OrderedItems([item("a", minute: 1), item("b", minute: 2), item("c", minute: 3)])
        ordered.update(ids: ["a", "c", "d"], fresh: [item("a", minute: 10), item("d", minute: 2)])
        #expect(ordered.items.map(\.id) == ["a", "b", "d"])
    }

    @Test func statusChangeKeepsThePlace() {
        var ordered = OrderedItems([item("a", minute: 1), item("b", minute: 2)])
        var b = item("b", minute: 2)
        b.status = .failed
        ordered.update(ids: ["b"], fresh: [b])
        #expect(ordered.items.map(\.id) == ["b", "a"])
        #expect(ordered.items[0].status == .failed)
    }

    /// Any sequence of updates leaves the same order as sorting everything from scratch.
    @Test func matchesAFullSortAfterManyRandomUpdates() {
        var rng = SystemRandomNumberGenerator()
        var truth: [String: MediaItem] = [:]
        for i in 0..<300 { truth["i\(i)"] = item("i\(i)", minute: Int.random(in: 0..<50, using: &rng)) }
        var ordered = OrderedItems(Array(truth.values))
        for _ in 0..<500 {
            let ids = Set((0..<Int.random(in: 1...5, using: &rng)).map { _ in "i\(Int.random(in: 0..<350, using: &rng))" })
            var fresh: [MediaItem] = []
            for id in ids {
                if Bool.random(using: &rng) {
                    let minute: Int? = Int.random(in: 0..<10, using: &rng) == 0 ? nil : Int.random(in: 0..<50, using: &rng)
                    let new = item(id, minute: minute)
                    truth[id] = new
                    fresh.append(new)
                } else {
                    truth[id] = nil
                }
            }
            ordered.update(ids: ids, fresh: fresh)
        }
        #expect(ordered.items.map(\.id) == truth.values.sorted(by: OrderedItems.precedes).map(\.id))
    }
}

@Suite struct OrderedItemsLocalTests {
    func item(_ id: String, local: String?, minute: Int) -> MediaItem {
        var m = MediaItem(localIdentifier: local, sha256: id, filename: id, kind: .photo,
                          creationDate: Date(timeIntervalSince1970: Double(minute * 60)), fileSize: 1, status: .backedUp)
        m.id = id
        return m
    }

    @Test func aPhotoWithTwoItemsShowsTheFirstInOrder() {
        var ordered = OrderedItems([item("old", local: "P", minute: 1), item("new", local: "P", minute: 5)])
        #expect(ordered.item(localIdentifier: "P")?.id == "new")
        ordered.update(ids: ["new"], fresh: [])
        #expect(ordered.item(localIdentifier: "P")?.id == "old")
        ordered.update(ids: ["old"], fresh: [])
        #expect(ordered.item(localIdentifier: "P") == nil)
    }

    @Test func linkingAndUnlinkingAPhotoFollowsTheItem() {
        var ordered = OrderedItems([item("a", local: nil, minute: 1)])
        ordered.update(ids: ["a"], fresh: [item("a", local: "P", minute: 1)])
        #expect(ordered.item(localIdentifier: "P")?.id == "a")
        ordered.update(ids: ["a"], fresh: [item("a", local: "Q", minute: 1)])
        #expect(ordered.item(localIdentifier: "P") == nil)
        #expect(ordered.item(localIdentifier: "Q")?.id == "a")
    }

    /// The lookup always agrees with "first item in order with this photo", whatever the updates.
    @Test func lookupMatchesAFullScanAfterManyRandomUpdates() {
        var rng = SystemRandomNumberGenerator()
        var truth: [String: MediaItem] = [:]
        func random(_ id: String) -> MediaItem {
            item(id, local: Bool.random(using: &rng) ? "P\(Int.random(in: 0..<20, using: &rng))" : nil, minute: Int.random(in: 0..<30, using: &rng))
        }
        for i in 0..<100 { truth["i\(i)"] = random("i\(i)") }
        var ordered = OrderedItems(Array(truth.values))
        for _ in 0..<500 {
            let ids = Set((0..<Int.random(in: 1...4, using: &rng)).map { _ in "i\(Int.random(in: 0..<120, using: &rng))" })
            var fresh: [MediaItem] = []
            for id in ids {
                if Int.random(in: 0..<4, using: &rng) == 0 { truth[id] = nil } else { let n = random(id); truth[id] = n; fresh.append(n) }
            }
            ordered.update(ids: ids, fresh: fresh)
        }
        let sorted = truth.values.sorted(by: OrderedItems.precedes)
        for p in 0..<20 {
            #expect(ordered.item(localIdentifier: "P\(p)")?.id == sorted.first { $0.localIdentifier == "P\(p)" }?.id)
        }
        #expect(ordered.items.map(\.id) == sorted.map(\.id))
    }
}

@Suite struct ScrubberTicksTests {
    private func marks(_ pairs: [(Int, Double)]) -> [ScrubberMark] { pairs.map { ScrubberMark(year: $0.0, fraction: $0.1) } }

    @Test func aLibraryFrom2015ShowsBothEnds() {
        // Newest first: 2026 at the top, 2015 at the bottom, with a quiet 2017 to 2019 in between.
        let m = marks([(2026, 0), (2025, 0.12), (2024, 0.25), (2023, 0.4), (2020, 0.55), (2016, 0.8), (2015, 0.93)])
        let ticks = ScrubberTicks.make(marks: m, maxLabels: 10)
        #expect(ticks.first?.year == 2026)
        #expect(ticks.last?.year == 2015)
        #expect(ticks.count == 7)
    }

    @Test func positionsComeFromTheLibraryNotFromEvenTime() {
        // 2026 holds nearly everything: 2015 sits close to the bottom, not 11 years' worth down an even scale.
        let ticks = ScrubberTicks.make(marks: marks([(2026, 0), (2015, 0.97)]), maxLabels: 10)
        #expect(ticks.map(\.year) == [2026, 2015])
        #expect(ticks[1].fraction == 0.97)
    }

    @Test func monthsOfOneYearBecomeOneLabelAtTheFirst() {
        let m = marks([(2024, 0), (2024, 0.1), (2024, 0.2), (2023, 0.5)])
        #expect(ScrubberTicks.make(marks: m, maxLabels: 10).map(\.year) == [2024, 2023])
        #expect(ScrubberTicks.make(marks: m, maxLabels: 10)[0].fraction == 0)
    }

    @Test func crowdedLabelsAreThinnedWithoutLosingTheTop() {
        let m = marks((0..<12).map { (2026 - $0, Double($0) / 12) })
        let ticks = ScrubberTicks.make(marks: m, maxLabels: 5)
        #expect(ticks.count <= 5)
        #expect(ticks.first?.year == 2026)
        for pair in zip(ticks, ticks.dropFirst()) { #expect(pair.1.fraction - pair.0.fraction >= 0.2 - 1e-9) }
    }

    @Test func emptyAndSingleYearAreSafe() {
        #expect(ScrubberTicks.make(marks: [], maxLabels: 8).isEmpty)
        #expect(ScrubberTicks.make(marks: marks([(2024, 0)]), maxLabels: 8).map(\.year) == [2024])
        #expect(ScrubberTicks.make(marks: marks([(2024, 0)]), maxLabels: 0).isEmpty)
    }

    @Test func badFractionsAreIgnoredOrClamped() {
        let m = marks([(2024, 0), (2023, .nan), (2022, 1.4)])
        let ticks = ScrubberTicks.make(marks: m, maxLabels: 10)
        #expect(ticks.map(\.year) == [2024, 2022])
        #expect(ticks.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
    }

    @Test func shortLibrariesGetNoMarks() {
        #expect(!ScrubberTicks.isLongEnough(contentHeight: 3000, viewportHeight: 800))
        #expect(ScrubberTicks.isLongEnough(contentHeight: 8000, viewportHeight: 800))
        #expect(!ScrubberTicks.isLongEnough(contentHeight: 8000, viewportHeight: 0))
    }
}

@Suite struct JumpToDateTests {
    private let cal = Calendar(identifier: .gregorian)

    private func day(_ y: Int, _ m: Int, _ d: Int = 15) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func emptyAndSingleStayAtTop() {
        #expect(JumpToDate.fraction(target: day(2023, 3), datesNewestFirst: []) == 0)
        #expect(JumpToDate.fraction(target: day(2023, 3), datesNewestFirst: [day(2024, 1)]) == 0)
    }

    @Test func newestFirstMapsTargetToScrubberFraction() {
        let dates = [day(2024, 6), day(2023, 6), day(2022, 6), day(2021, 6)]
        #expect(JumpToDate.fraction(target: day(2024, 6), datesNewestFirst: dates) == 0)
        #expect(JumpToDate.fraction(target: day(2023, 6), datesNewestFirst: dates) == 1.0 / 3)
        #expect(JumpToDate.fraction(target: day(2021, 6), datesNewestFirst: dates) == 1)
        // Between 2023 and 2022: lands on the first date at or older than the target.
        #expect(JumpToDate.fraction(target: day(2022, 12), datesNewestFirst: dates) == 2.0 / 3)
    }

    @Test func olderThanLibraryGoesToBottom() {
        let dates = [day(2024, 1), day(2023, 1)]
        #expect(JumpToDate.fraction(target: day(2010, 1), datesNewestFirst: dates) == 1)
    }

    @Test func yearRangeSpansLibraryAndToday() {
        let dates = [day(2020, 1), day(2018, 6)]
        let range = JumpToDate.yearRange(in: dates, calendar: cal, now: day(2024, 5))
        #expect(range == 2018...2024)
        #expect(JumpToDate.yearRange(in: [], calendar: cal, now: day(2024, 5)) == 2024...2024)
    }
}

@Suite struct ScrollLoadPolicyTests {
    @Test func defersAtThresholdAndResumesBelowLowerOne() {
        var p = ScrollLoadPolicy()
        #expect(p.update(speedPointsPerSecond: 2999) == false)
        #expect(p.update(speedPointsPerSecond: 3000) == true)
        #expect(p.update(speedPointsPerSecond: 2000) == true)
        #expect(p.update(speedPointsPerSecond: 1800) == true)
        #expect(p.update(speedPointsPerSecond: 1799) == false)
        #expect(p.update(speedPointsPerSecond: 2500) == false)
    }

    @Test func nanAndNegativeCountAsZero() {
        var p = ScrollLoadPolicy()
        #expect(p.update(speedPointsPerSecond: .nan) == false)
        #expect(p.update(speedPointsPerSecond: -5000) == false)
        #expect(p.update(speedPointsPerSecond: .infinity) == false)
        _ = p.update(speedPointsPerSecond: 4000)
        #expect(p.update(speedPointsPerSecond: .nan) == false)
    }

    @Test func repeatedUpdatesAreStable() {
        var p = ScrollLoadPolicy()
        for _ in 0..<5 { #expect(p.update(speedPointsPerSecond: 5000) == true) }
        for _ in 0..<5 { #expect(p.update(speedPointsPerSecond: 2400) == true) }
        for _ in 0..<5 { #expect(p.update(speedPointsPerSecond: 0) == false) }
    }

    @Test func prefetchShrinksWithSpeed() {
        #expect(ScrollLoadPolicy.prefetchCount(speed: 0) == 30)
        #expect(ScrollLoadPolicy.prefetchCount(speed: 2000) == 12)
        #expect(ScrollLoadPolicy.prefetchCount(speed: 3000) == 0)
        #expect(ScrollLoadPolicy.prefetchCount(speed: .nan) == 30)
        #expect(ScrollLoadPolicy.prefetchCount(speed: -1) == 30)
    }
}

@Suite struct MarqueeSelectionTests {
    @Test func rectFromAnyCornerAndClamped() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 200)
        #expect(MarqueeSelection.rect(from: CGPoint(x: 50, y: 60), to: CGPoint(x: 10, y: 20), within: bounds)
                == CGRect(x: 10, y: 20, width: 40, height: 40))
        #expect(MarqueeSelection.rect(from: CGPoint(x: 50, y: 60), to: CGPoint(x: 500, y: -30), within: bounds)
                == CGRect(x: 50, y: 0, width: 50, height: 60))
    }

    @Test func plainBandReplacesAndModifierToggles() {
        let base: Set<String> = ["a", "b"]
        #expect(MarqueeSelection.result(base: base, touched: ["b", "c"], toggle: false) == ["b", "c"])
        #expect(MarqueeSelection.result(base: base, touched: ["b", "c"], toggle: true) == ["a", "c"])
        #expect(MarqueeSelection.result(base: base, touched: [], toggle: true) == base)
    }

    @Test func autoScrollSpeedGrowsNearEdges() {
        func step(_ y: CGFloat) -> CGFloat { MarqueeSelection.autoScrollStep(pointerY: y, visibleMinY: 0, visibleMaxY: 600) }
        #expect(step(300) == 0)
        #expect(step(10) < 0 && step(550) > 0)
        #expect(abs(step(5)) > abs(step(50)))
        #expect(step(2000) == 30 && step(-500) == -30)
    }
}
