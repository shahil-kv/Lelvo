import Foundation
import Testing
import MemvoCore

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

    /// The next `didChange` from `store` (posted asynchronously on the main queue).
    @MainActor func nextChange(of store: LibraryStore, _ body: () throws -> Void) async throws -> Notification {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Notification, Error>) in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: store, queue: .main) { note in
                if let token { NotificationCenter.default.removeObserver(token) }
                c.resume(returning: note)
            }
            do { try body() } catch { c.resume(throwing: error) }
        }
    }

    @Test @MainActor func upsertReportsTheChangedIds() async throws {
        let store = try LibraryStore(url: nil)
        let a = item("a"), b = item("b")
        let note = try await nextChange(of: store) { try store.upsert([a, b]) }
        #expect(LibraryStore.changedIds(note) == [a.id, b.id])
    }

    @Test @MainActor func deleteReportsItsIdAndDeleteAllReportsEverything() async throws {
        let store = try LibraryStore(url: nil)
        let a = item("a")
        _ = try await nextChange(of: store) { try store.upsert(a) }
        let deleted = try await nextChange(of: store) { try store.delete(id: a.id) }
        #expect(LibraryStore.changedIds(deleted) == [a.id])
        let cleared = try await nextChange(of: store) { try store.deleteAll() }
        #expect(LibraryStore.changedIds(cleared) == nil)
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
