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
