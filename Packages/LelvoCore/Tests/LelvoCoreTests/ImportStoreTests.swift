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

    /// The date that was actually written has to be in the index. The result list reads it again after a relaunch.
    @Test func testDateUsedIsStoredWithThePlan() throws {
        let store = try LibraryStore(url: nil)
        var item = planned(key: "k")
        item.dateSource = .fileWillTell
        item.dateUsed = .zipModified
        try store.upsertPlanned([item])
        try store.setImportStatus(key: "k", status: .done, itemId: "item-1", error: nil)
        let again = try store.importItems(status: .done)
        #expect(again.first?.0.dateUsed == .zipModified)
        #expect(again.first?.0.dateSource == .fileWillTell)
    }

    /// A catalogue rebuild upserts the plan it read, which has no `dateUsed`. Send may already have stored one
    /// while the row is still pending. That choice has to survive, including after the row is done: a later
    /// catalogue does not write a finished row again. Only the zip's modified date is the undated list.
    @Test func testCatalogueUpsertKeepsStoredDateUsed() throws {
        let store = try LibraryStore(url: nil)
        for source: TakeoutDateChoice.Source in [.google, .file, .zipModified] {
            var stored = planned(key: source.rawValue)
            stored.dateSource = .fileWillTell
            stored.dateUsed = source
            try store.upsertPlanned([stored])

            var catalogue = planned(key: source.rawValue)
            catalogue.dateSource = .fileWillTell
            catalogue.albums = ["Trip"]
            catalogue.dateUsed = nil
            try store.upsertPlanned([catalogue])

            let pending = try store.importItems(status: .pending).first { $0.0.key == source.rawValue }
            #expect(pending?.0.dateUsed == source)
            #expect(pending?.0.albums == ["Trip"])
            #expect(pending?.1 == .pending)
            #expect(TakeoutDateChoice.importedWithoutGoogleDate(pending?.0.dateUsed) == (source == .zipModified))

            try store.setImportStatus(key: source.rawValue, status: .done, itemId: "item-\(source.rawValue)", error: nil)
            var again = catalogue
            again.albums = ["Later"]
            try store.upsertPlanned([again])
            let done = try store.importItems(status: .done).first { $0.0.key == source.rawValue }
            #expect(done?.0.dateUsed == source)
            #expect(done?.1 == .done)
            #expect(TakeoutDateChoice.importedWithoutGoogleDate(done?.0.dateUsed) == (source == .zipModified))
        }

        var chosen = planned(key: "fresh")
        var named = planned(key: "split")
        named.uploadedSeparately = ["IMG_1-edited.jpg"]
        try store.upsertPlanned([named])
        var catalogue = planned(key: "split")
        catalogue.uploadedSeparately = nil
        catalogue.albums = ["Trip"]
        try store.upsertPlanned([catalogue])
        let kept = try store.importItems(status: .pending).first { $0.0.key == "split" }
        #expect(kept?.0.uploadedSeparately == ["IMG_1-edited.jpg"])
        #expect(kept?.0.albums == ["Trip"])

        chosen.dateUsed = nil
        try store.upsertPlanned([chosen])
        chosen.dateUsed = .zipModified
        try store.upsertPlanned([chosen])
        let fresh = try store.importItems(status: nil).first { $0.0.key == "fresh" }
        #expect(fresh?.0.dateUsed == .zipModified)
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
    /// One row by key, without decoding the whole table: the importer reads a row per photo.
    @Test func testImportItemByKey() throws {
        let store = try LibraryStore(url: nil)
        try store.upsertPlanned([planned(key: "a"), planned(key: "b")])
        try store.setImportStatus(key: "b", status: .uploading, itemId: "x", error: nil)
        let row = try store.importItem(key: "b")
        #expect(row?.0.key == "b")
        #expect(row?.1 == .uploading)
        #expect(row?.2 == "x")
        #expect(try store.importItem(key: "missing") == nil)
    }

    /// Resumed uploads first, then pending, then failed; each by key. Nothing else is work.
    @Test func testWorkKeysOrder() throws {
        let store = try LibraryStore(url: nil)
        try store.upsertPlanned(["a", "b", "c", "d", "e", "f"].map { planned(key: $0) })
        try store.setImportStatus(key: "a", status: .failed, itemId: nil, error: "x")
        try store.setImportStatus(key: "c", status: .uploading, itemId: "i", error: nil)
        try store.setImportStatus(key: "d", status: .done, itemId: "i", error: nil)
        try store.setImportStatus(key: "e", status: .waitingForDetails, itemId: nil, error: nil)
        #expect(try store.importWorkKeys() == ["c", "b", "f", "a"])
    }

    /// Every finished source in one pass; an album copy in another zip keeps that zip open too.
    @Test func testFinishedSourceIds() throws {
        let store = try LibraryStore(url: nil)
        let copy = TakeoutSourceEntry(sourceId: "C", entry: ZipEntry(path: "Takeout/Google Photos/Goa/a.jpg",
                                      compressedSize: 100, size: 100, crc32: 1, method: 0, localHeaderOffset: 0, modified: nil))
        try store.upsertPlanned([planned(key: "a", source: "A", copies: [copy]), planned(key: "b", source: "B")])
        try store.setImportStatus(key: "b", status: .done, itemId: "x", error: nil)
        #expect(try store.finishedSourceIds(["A", "B", "C", "D"]) == ["B", "D"])
        try store.setImportStatus(key: "a", status: .duplicate, itemId: "y", error: nil)
        #expect(try store.finishedSourceIds(["A", "B", "C", "D"]) == ["A", "B", "C", "D"])
    }

    /// The import screen's photo strip: the newest imported items first, only ones that are done.
    @Test func testRecentImportedItemIds() throws {
        let store = try LibraryStore(url: nil)
        try store.upsertPlanned(["a", "b", "c", "d"].map { planned(key: $0) })
        try store.setImportStatus(key: "a", status: .done, itemId: "ia", error: nil)
        try store.setImportStatus(key: "b", status: .failed, itemId: "ib", error: "x")
        Thread.sleep(forTimeInterval: 0.01)
        try store.setImportStatus(key: "c", status: .done, itemId: "ic", error: nil)
        try store.setImportStatus(key: "d", status: .duplicate, itemId: "id", error: nil)
        #expect(try store.recentImportedItemIds(limit: 6) == ["ic", "ia"])
        #expect(try store.recentImportedItemIds(limit: 1) == ["ic"])
    }
}
