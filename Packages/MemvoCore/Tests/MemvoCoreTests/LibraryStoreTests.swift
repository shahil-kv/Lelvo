import Foundation
import SQLite3
import Testing
import MemvoCore

@Suite struct LibraryStoreTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite")
    }

    func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    func item(_ n: Int, status: ItemStatus = .backedUp) -> MediaItem {
        MediaItem(localIdentifier: "L\(n)", sha256: "h\(n)", filename: "IMG_\(n).HEIC", kind: .photo,
                  creationDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + n)), fileSize: Int64(n), status: status)
    }

    /// A database made before schema versions were kept opens with its items and is marked current.
    @Test func migratesAnUnversionedDatabase() throws {
        let url = tempURL()
        defer { remove(url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE items (id TEXT PRIMARY KEY, local_id TEXT, sha256 TEXT NOT NULL, status TEXT NOT NULL, creation_date REAL, json BLOB NOT NULL);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE aliases (local_id TEXT PRIMARY KEY, item_id TEXT NOT NULL);
        INSERT INTO meta VALUES ('k', 'v');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try LibraryStore(url: url)
        #expect(store.schemaVersion >= 1)
        #expect(store.meta("k") == "v")
        try store.upsert(item(2))
        #expect(try store.allItems().map(\.filename) == ["IMG_2.HEIC"])
        let version = store.schemaVersion
        let reopened = try LibraryStore(url: url)
        #expect(reopened.schemaVersion == version)
        #expect(reopened.meta("k") == "v")
    }

    /// Reads go through the second connection and must see every committed write at once, through cached statements.
    @Test func readsSeeWritesAtOnce() throws {
        let url = tempURL()
        defer { remove(url) }
        let store = try LibraryStore(url: url)
        let items = (0..<2000).map { item($0) }
        try store.upsert(items)
        #expect(try store.counts() == [.backedUp: 2000])
        for n in 0..<50 {
            _ = try store.update(id: items[n].id) { $0.status = .failed }
            #expect(try store.item(id: items[n].id)?.status == .failed)
        }
        #expect(try store.items(status: .failed).count == 50)
        #expect(try store.item(localIdentifier: "L7")?.status == .failed)
        #expect(try store.items(ids: items[0..<1200].map(\.id)).count == 1200)
        try store.delete(id: items[0].id)
        #expect(try store.item(id: items[0].id) == nil)
        store.setMeta("token", "abc")
        #expect(store.meta("token") == "abc")
        #expect(try store.knownLocalIdentifiers().count == 1999)
    }

    /// Reading from other threads while a large write runs neither fails nor sees a half-written batch.
    @Test func readsDuringALongWriteSeeWholeCommits() async throws {
        let url = tempURL()
        defer { remove(url) }
        let store = try LibraryStore(url: url)
        let batch = (0..<5000).map { item($0) }
        async let write: Void = Task.detached { try store.upsert(batch) }.value
        var seen = Set<Int>()
        for _ in 0..<20 {
            let n = try await Task.detached { try store.counts()[.backedUp] ?? 0 }.value
            seen.insert(n)
        }
        try await write
        #expect(seen.isSubset(of: [0, 5000]))
        #expect(try store.counts()[.backedUp] == 5000)
    }

    @Test func searchWordsAreStoredAndMigrated() throws {
        let url = tempURL()
        defer { remove(url) }
        let store = try LibraryStore(url: url)
        #expect(store.schemaVersion == 2)
        try store.setSearch(key: "A", stamp: "1", words: "beach sunset")
        try store.setSearch(key: "B", stamp: "2", words: "")
        #expect(try store.searchStamps() == ["A": "1", "B": "2"])
        #expect(try store.searchWords() == ["A": "beach sunset"])
        try store.deleteSearch(keys: ["A"])
        #expect(try store.searchWords().isEmpty)
        try store.deleteAll()
        #expect(try store.searchStamps().isEmpty)
    }
}
