import Foundation
import SQLite3
import Testing
@testable import LelvoCore

@Suite struct ImportStoreTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("import-store-\(UUID().uuidString).sqlite")
    }

    func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    func source(_ id: String, kind: String = "zip") -> ImportSourceRecord {
        ImportSourceRecord(id: id, kind: kind, name: "\(id).zip", bookmark: Data([1, 2, 3]), size: 100,
                           addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func planned(key: String, source: String = "A", copies: [TakeoutSourceEntry] = []) -> TakeoutPlannedItem {
        TakeoutPlannedItem(
            key: key, kind: .photo,
            primary: TakeoutSourceEntry(sourceId: source, entry: ZipEntry(
                path: "Takeout/Google Photos/Photos from 2019/\(key).jpg",
                compressedSize: 100, size: 100, crc32: 1, method: 0, localHeaderOffset: 0, modified: nil)),
            pairedVideo: nil, edited: nil, copies: copies, albums: [], sidecar: nil, dateSource: .google)
    }

    /// A new store is version 7; a file left at version 6 grows the import tables on open.
    @Test func testMigrationCreatesImportTables() throws {
        let fresh = try LibraryStore(url: nil)
        #expect(fresh.schemaVersion == 7)

        let url = tempURL()
        defer { remove(url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE items (id TEXT PRIMARY KEY, local_id TEXT, sha256 TEXT NOT NULL, status TEXT NOT NULL, creation_date REAL, json BLOB NOT NULL);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE aliases (local_id TEXT PRIMARY KEY, item_id TEXT NOT NULL);
        CREATE TABLE search (key TEXT PRIMARY KEY, stamp TEXT NOT NULL, words TEXT NOT NULL, things TEXT NOT NULL DEFAULT '', score REAL, utility INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE trash_notes (message_id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE trash_outbox (item_id TEXT PRIMARY KEY, chat_id TEXT NOT NULL, op TEXT NOT NULL);
        CREATE TABLE no_backup (key TEXT PRIMARY KEY);
        CREATE TABLE meta_notes (message_id TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE meta_outbox (item_id TEXT NOT NULL, key TEXT NOT NULL, chat_id TEXT NOT NULL, value INTEGER NOT NULL, PRIMARY KEY (item_id, key));
        CREATE TABLE photos_favorite (item_id TEXT PRIMARY KEY, value INTEGER NOT NULL);
        PRAGMA user_version = 6;
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try LibraryStore(url: url)
        #expect(store.schemaVersion == 7)
        try store.addImportSource(source("A"))
        #expect(try store.importSources() == [source("A")])
        try store.removeImportSource(id: "A")
        #expect(try store.importSources().isEmpty)
    }

    /// Re-planning an item that already uploaded must not lose its status or library id.
    @Test func testUpsertKeepsProgress() throws {
        let store = try LibraryStore(url: nil)
        var item = planned(key: "k")
        try store.upsertPlanned([item])
        try store.setImportStatus(key: "k", status: .done, itemId: "item-1", error: nil)
        item.albums = ["Goa 2019"]
        try store.upsertPlanned([item])
        let rows = try store.importItems(status: nil)
        #expect(rows.count == 1)
        #expect(rows[0].0.key == "k")
        #expect(rows[0].0.albums == ["Goa 2019"])
        #expect(rows[0].1 == .done)
        #expect(rows[0].2 == "item-1")
        #expect(try store.importItems(status: .done).count == 1)
        #expect(try store.importItems(status: .pending).isEmpty)
    }

    /// A zip is finished only when every file from it is done, a duplicate, or skipped.
    @Test func testSourceFinishedOnlyWhenAllEntriesSettled() throws {
        let store = try LibraryStore(url: nil)
        try store.addImportSource(source("A"))
        try store.upsertPlanned([planned(key: "k1", source: "A")])
        #expect(try store.isSourceFinished(id: "A") == false)

        try store.setImportStatus(key: "k1", status: .done, itemId: "id1", error: nil)
        #expect(try store.isSourceFinished(id: "A") == true)

        let copy = TakeoutSourceEntry(sourceId: "A", entry: ZipEntry(
            path: "Takeout/Google Photos/Goa 2019/k2.jpg",
            compressedSize: 100, size: 100, crc32: 2, method: 0, localHeaderOffset: 0, modified: nil))
        try store.upsertPlanned([
            planned(key: "k1", source: "A"),
            planned(key: "k2", source: "B", copies: [copy]),
            planned(key: "k3", source: "A"),
        ])
        #expect(try store.isSourceFinished(id: "A") == false)
        try store.setImportStatus(key: "k2", status: .duplicate, itemId: nil, error: nil)
        try store.setImportStatus(key: "k3", status: .skipped, itemId: nil, error: nil)
        #expect(try store.isSourceFinished(id: "A") == true)

        try store.setImportStatus(key: "k3", status: .failed, itemId: nil, error: "no date")
        #expect(try store.isSourceFinished(id: "A") == false)
    }

    @Test func testCounts() throws {
        let store = try LibraryStore(url: nil)
        try store.upsertPlanned([planned(key: "a"), planned(key: "b"), planned(key: "c")])
        try store.setImportStatus(key: "c", status: .done, itemId: "x", error: nil)
        #expect(try store.importCounts() == [.pending: 2, .done: 1])
        try store.clearImport()
        #expect(try store.importCounts().isEmpty)
        try store.addImportSource(source("A"))
        try store.upsertPlanned([planned(key: "a")])
        try store.deleteAll()
        #expect(try store.importSources().isEmpty)
        #expect(try store.importItems(status: nil).isEmpty)
    }
}
