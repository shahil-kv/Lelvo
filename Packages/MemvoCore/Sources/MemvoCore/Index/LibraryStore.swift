import Foundation
import SQLite3

public enum StoreError: Error, LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        if case .sqlite(let m) = self { return "Database error: \(m)" }
        return nil
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local database of every item the app knows about. SQLite with indexed lookup columns and the
/// full `MediaItem` stored as JSON, so the schema stays stable while the model evolves.
///
/// Writes go through one connection; reads from outside go through a second, read-only one. In WAL mode a reader sees
/// the last commit without waiting, so the timeline's reads no longer queue behind a backup's writes.
public final class LibraryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    /// Prepared statements by SQL, per connection (preparing again on every call made `upsert` of 10k items prepare 10k times).
    private var statements: [String: OpaquePointer] = [:]
    private var readDB: OpaquePointer?
    private let readLock = NSLock()
    private var readStatements: [String: OpaquePointer] = [:]
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    /// Posted (on an arbitrary thread) whenever items change.
    public static let didChange = Notification.Name("LibraryStoreDidChange")
    private static let changedIdsKey = "ids"

    /// The ids of the items a `didChange` notification is about, or nil when anything may have changed.
    /// Lets the timeline reload just those items instead of decoding the whole store during a backup.
    public static func changedIds(_ note: Notification) -> Set<String>? {
        note.userInfo?[changedIdsKey] as? Set<String>
    }

    /// Pass `nil` for an in-memory database (tests).
    public init(url: URL?) throws {
        let path = url?.path ?? ":memory:"
        if let url { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.sqlite("open failed")
        }
        // Wait for a moment instead of failing with "database is locked" when another connection is busy, e.g. the
        // last one to close still checkpointing the write-ahead log.
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL;")
        // In WAL mode NORMAL skips the fsync on every commit (the backup commits after every part). A crash can lose the
        // last commits but never corrupts the database, and the channel is the source of truth for what was uploaded.
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            local_id TEXT,
            sha256 TEXT NOT NULL,
            status TEXT NOT NULL,
            creation_date REAL,
            json BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_items_local ON items(local_id);
        CREATE INDEX IF NOT EXISTS idx_items_sha ON items(sha256);
        CREATE INDEX IF NOT EXISTS idx_items_status ON items(status);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS aliases (local_id TEXT PRIMARY KEY, item_id TEXT NOT NULL);
        """)
        try migrate()
        try normalizeItemIds()
        if let url {
            // A second connection to ":memory:" would be a different, empty database: tests read through the writer.
            guard sqlite3_open_v2(url.path, &readDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(readDB)
                readDB = nil
                return
            }
            sqlite3_busy_timeout(readDB, 5000)
        }
    }

    /// Schema changes in order: entry `i` takes a database from `PRAGMA user_version` `i` to `i + 1`. Version 0 is a
    /// database from before versions were kept, which already has the tables created above.
    private static let migrations: [String] = [
        "", // 0 → 1: start counting.
        // 1 → 2: words Vision found in each photo, for on-device search (#14). `key` is the timeline entry id; `stamp`
        // says which version of the photo was read, so an edited photo is read again.
        "CREATE TABLE IF NOT EXISTS search (key TEXT PRIMARY KEY, stamp TEXT NOT NULL, words TEXT NOT NULL);",
        // 2 → 3: Vision's labels and quality score for Memories' themes and covers (#12); rows are read again.
        """
        ALTER TABLE search ADD COLUMN things TEXT NOT NULL DEFAULT '';
        ALTER TABLE search ADD COLUMN score REAL;
        ALTER TABLE search ADD COLUMN utility INTEGER NOT NULL DEFAULT 0;
        DELETE FROM search;
        """,
    ]

    /// The database's schema version (`PRAGMA user_version`).
    public var schemaVersion: Int {
        (try? withStatement("PRAGMA user_version;") { sqlite3_step($0) == SQLITE_ROW ? Int(sqlite3_column_int64($0, 0)) : 0 }) ?? 0
    }

    private func migrate() throws {
        lock.lock(); defer { lock.unlock() }
        let current = schemaVersion
        guard current < Self.migrations.count else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            for version in current ..< Self.migrations.count {
                if !Self.migrations[version].isEmpty { try exec(Self.migrations[version]) }
            }
            try exec("PRAGMA user_version = \(Self.migrations.count);")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Older builds created uppercase item ids while captions store them lowercase, so every scan added an
    /// unlinked cloud copy and a full scan marked the phone's item "not found". Folds each uppercase item
    /// into its scanned twin (keeping the phone link and queue state), or renames it.
    private func normalizeItemIds() throws {
        lock.lock(); defer { lock.unlock() }
        let mixed = try withStatement("SELECT json FROM items WHERE id <> lower(id);", readItems)
        guard !mixed.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            for old in mixed {
                var item = old
                item.id = old.id.lowercased()
                if var twin = try writerItem(id: item.id) {
                    twin.localIdentifier = twin.localIdentifier ?? old.localIdentifier
                    twin.verifiedAt = twin.verifiedAt ?? old.verifiedAt
                    twin.favorite = twin.favorite ?? old.favorite
                    if twin.status != .backedUp, old.status == .queued || old.status == .uploading {
                        twin.status = old.status
                        twin.lastError = old.lastError
                    }
                    item = twin
                }
                try withStatement("DELETE FROM items WHERE id = ?;", bind: { bindText($0, 1, old.id) }) { _ = sqlite3_step($0) }
                try insert(item)
            }
            try exec("UPDATE aliases SET item_id = lower(item_id);")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    deinit {
        // A connection with statements left open doesn't close.
        statements.values.forEach { sqlite3_finalize($0) }
        readStatements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(db)
        sqlite3_close(readDB)
    }

    /// Opens the database at `url`; if it is corrupt, moves it aside and starts fresh (the channel is the
    /// source of truth, so a rescan restores everything). Falls back to memory only if the disk is unusable.
    public static func openOrFallback(url: URL) -> LibraryStore {
        if let store = try? LibraryStore(url: url) { return store }
        let aside = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: aside)
        if let store = try? LibraryStore(url: url) { return store }
        if let store = try? LibraryStore(url: nil) { return store }
        fatalError("SQLite is unavailable")
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqlite(msg)
        }
    }

    /// Runs `sql` on the writing connection. `cache: false` for SQL that varies (`IN` lists of any length).
    private func withStatement<T>(_ sql: String, cache: Bool = true, bind: (OpaquePointer?) -> Void = { _ in },
                                  _ body: (OpaquePointer?) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try Self.run(sql, on: db, cache: cache ? \.statements : nil, of: self, bind: bind, body)
    }

    /// Runs a read on the read-only connection (the writer when there is none, e.g. in memory). Reads that are part of a
    /// write (`update`, the id fix-up) stay on the writer, which sees its own uncommitted changes.
    private func withReadStatement<T>(_ sql: String, cache: Bool = true, bind: (OpaquePointer?) -> Void = { _ in },
                                      _ body: (OpaquePointer?) throws -> T) throws -> T {
        guard let readDB else { return try withStatement(sql, cache: cache, bind: bind, body) }
        readLock.lock(); defer { readLock.unlock() }
        return try Self.run(sql, on: readDB, cache: cache ? \.readStatements : nil, of: self, bind: bind, body)
    }

    /// The caller holds the connection's lock. A cached statement is taken out of the cache while it runs, so a nested
    /// use of the same SQL prepares its own instead of resetting this one.
    private static func run<T>(_ sql: String, on db: OpaquePointer?, cache: ReferenceWritableKeyPath<LibraryStore, [String: OpaquePointer]>?,
                               of store: LibraryStore, bind: (OpaquePointer?) -> Void, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var stmt = cache.flatMap { store[keyPath: $0].removeValue(forKey: sql) }
        if stmt == nil {
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
        defer {
            if let cache, store[keyPath: cache][sql] == nil {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                store[keyPath: cache][sql] = stmt
            } else {
                sqlite3_finalize(stmt)
            }
        }
        bind(stmt)
        return try body(stmt)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func readItems(_ stmt: OpaquePointer?) throws -> [MediaItem] {
        var result: [MediaItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            if let item = try? decoder.decode(MediaItem.self, from: data) { result.append(item) }
        }
        return result
    }

    // MARK: - Items

    public func upsert(_ item: MediaItem) throws {
        try upsert([item])
    }

    public func upsert(_ items: [MediaItem]) throws {
        guard !items.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        do {
            for item in items { try insert(item) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        notifyChanged(ids: Set(items.map(\.id)))
    }

    private func insert(_ item: MediaItem) throws {
        let json = try encoder.encode(item)
        try withStatement("INSERT OR REPLACE INTO items (id, local_id, sha256, status, creation_date, json) VALUES (?,?,?,?,?,?);", bind: { s in
            bindText(s, 1, item.id)
            bindText(s, 2, item.localIdentifier)
            bindText(s, 3, item.sha256)
            bindText(s, 4, item.status.rawValue)
            if let d = item.creationDate { sqlite3_bind_double(s, 5, d.timeIntervalSince1970) } else { sqlite3_bind_null(s, 5) }
            _ = json.withUnsafeBytes { sqlite3_bind_blob(s, 6, $0.baseAddress, Int32(json.count), SQLITE_TRANSIENT) }
        }) { s in
            guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
    }

    /// Posted asynchronously: observers run on the main queue, and a synchronous post from a writer that
    /// still holds `lock` (e.g. inside `update`) deadlocks against any main-thread read.
    private func notifyChanged(ids: Set<String>?) {
        let info = ids.map { [Self.changedIdsKey: $0] }
        DispatchQueue.main.async { [weak self] in NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: info) }
    }

    /// Atomically reads, modifies and writes one item.
    @discardableResult
    public func update(id: String, _ change: (inout MediaItem) -> Void) throws -> MediaItem? {
        lock.lock(); defer { lock.unlock() }
        guard var item = try writerItem(id: id) else { return nil }
        change(&item)
        try upsert(item)
        return item
    }

    public func item(id: String) throws -> MediaItem? {
        try withReadStatement("SELECT json FROM items WHERE id = ? LIMIT 1;", bind: { bindText($0, 1, id) }, readItems).first
    }

    private func writerItem(id: String) throws -> MediaItem? {
        try withStatement("SELECT json FROM items WHERE id = ? LIMIT 1;", bind: { bindText($0, 1, id) }, readItems).first
    }

    /// Looks up by local identifier, including duplicate assets aliased to an item.
    public func item(localIdentifier: String) throws -> MediaItem? {
        if let direct = try withReadStatement("SELECT json FROM items WHERE local_id = ? LIMIT 1;", bind: { bindText($0, 1, localIdentifier) }, readItems).first {
            return direct
        }
        return try withReadStatement("SELECT items.json FROM aliases JOIN items ON items.id = aliases.item_id WHERE aliases.local_id = ? LIMIT 1;",
                                 bind: { bindText($0, 1, localIdentifier) }, readItems).first
    }

    /// Duplicate assets recorded by `addAlias`: (asset local identifier, item id).
    public func aliases() throws -> [(localIdentifier: String, itemId: String)] {
        try withReadStatement("SELECT local_id, item_id FROM aliases;") { s in
            var out: [(String, String)] = []
            while sqlite3_step(s) == SQLITE_ROW {
                if let a = sqlite3_column_text(s, 0), let b = sqlite3_column_text(s, 1) { out.append((String(cString: a), String(cString: b))) }
            }
            return out
        }
    }

    public func removeAlias(localIdentifier: String) throws {
        try withStatement("DELETE FROM aliases WHERE local_id = ?;", bind: { bindText($0, 1, localIdentifier) }) { _ = sqlite3_step($0) }
    }

    /// Records another asset with identical content so it is never hashed or uploaded again.
    public func addAlias(localIdentifier: String, itemId: String) throws {
        try withStatement("INSERT OR REPLACE INTO aliases (local_id, item_id) VALUES (?, ?);",
                          bind: { bindText($0, 1, localIdentifier); bindText($0, 2, itemId) }) { _ = sqlite3_step($0) }
    }

    /// The items with these ids that exist (in no particular order).
    public func items(ids: some Collection<String>) throws -> [MediaItem] {
        var result: [MediaItem] = []
        let all = Array(ids)
        // SQLite allows 999 bound parameters in older builds.
        for start in stride(from: 0, to: all.count, by: 500) {
            let batch = all[start..<min(start + 500, all.count)]
            let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
            result += try withReadStatement("SELECT json FROM items WHERE id IN (\(marks));", cache: false, bind: { s in
                for (i, id) in batch.enumerated() { bindText(s, Int32(i + 1), id) }
            }, readItems)
        }
        return result
    }

    public func items(sha256: String) throws -> [MediaItem] {
        try withReadStatement("SELECT json FROM items WHERE sha256 = ?;", bind: { bindText($0, 1, sha256) }, readItems)
    }

    public func items(status: ItemStatus) throws -> [MediaItem] {
        try withReadStatement("SELECT json FROM items WHERE status = ? ORDER BY creation_date DESC;", bind: { bindText($0, 1, status.rawValue) }, readItems)
    }

    public func allItems() throws -> [MediaItem] {
        try withReadStatement("SELECT json FROM items ORDER BY creation_date DESC;", readItems)
    }

    /// All local identifiers the store knows, for fast scanning.
    public func knownLocalIdentifiers() throws -> Set<String> {
        try withReadStatement("SELECT local_id FROM items WHERE local_id IS NOT NULL UNION SELECT local_id FROM aliases;") { s in
            var set = Set<String>()
            while sqlite3_step(s) == SQLITE_ROW {
                if let c = sqlite3_column_text(s, 0) { set.insert(String(cString: c)) }
            }
            return set
        }
    }

    public func counts() throws -> [ItemStatus: Int] {
        try withReadStatement("SELECT status, COUNT(*) FROM items GROUP BY status;") { s in
            var result: [ItemStatus: Int] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                if let c = sqlite3_column_text(s, 0), let st = ItemStatus(rawValue: String(cString: c)) {
                    result[st] = Int(sqlite3_column_int64(s, 1))
                }
            }
            return result
        }
    }

    public func delete(id: String) throws {
        try withStatement("DELETE FROM items WHERE id = ?;", bind: { bindText($0, 1, id) }) { _ = sqlite3_step($0) }
        try withStatement("DELETE FROM aliases WHERE item_id = ?;", bind: { bindText($0, 1, id) }) { _ = sqlite3_step($0) }
        notifyChanged(ids: [id])
    }

    /// Deletes the item only if it is still queued. For cleanup that works from an earlier read: an upload may have
    /// started since, and its row must stay. Returns whether a row was deleted.
    @discardableResult
    public func deleteIfQueued(id: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deleted = try withStatement("DELETE FROM items WHERE id = ? AND status = ?;", bind: {
            bindText($0, 1, id)
            bindText($0, 2, ItemStatus.queued.rawValue)
        }) { _ = sqlite3_step($0); return sqlite3_changes(db) > 0 }
        guard deleted else { return false }
        try withStatement("DELETE FROM aliases WHERE item_id = ?;", bind: { bindText($0, 1, id) }) { _ = sqlite3_step($0) }
        notifyChanged(ids: [id])
        return true
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DELETE FROM items; DELETE FROM meta; DELETE FROM aliases; DELETE FROM search;")
        notifyChanged(ids: nil)
    }

    // MARK: - Search (#14)

    /// Which version of each entry the search index has read.
    public func searchStamps() throws -> [String: String] {
        try withReadStatement("SELECT key, stamp FROM search;") { s in
            var out: [String: String] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                if let k = sqlite3_column_text(s, 0), let v = sqlite3_column_text(s, 1) { out[String(cString: k)] = String(cString: v) }
            }
            return out
        }
    }

    /// Every entry's indexed words.
    public func searchWords() throws -> [String: String] {
        try withReadStatement("SELECT key, words FROM search WHERE words <> '';") { s in
            var out: [String: String] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                if let k = sqlite3_column_text(s, 0), let v = sqlite3_column_text(s, 1) { out[String(cString: k)] = String(cString: v) }
            }
            return out
        }
    }

    /// What Vision found per entry for Memories: its labels, aesthetics score and whether it's a screenshot or document.
    public struct PhotoFacts: Equatable, Sendable {
        public let things: [String]
        public let score: Double?
        public let utility: Bool

        public init(things: [String], score: Double?, utility: Bool) {
            self.things = things
            self.score = score
            self.utility = utility
        }
    }

    public func photoFacts() throws -> [String: PhotoFacts] {
        try withReadStatement("SELECT key, things, score, utility FROM search WHERE things <> '' OR score IS NOT NULL OR utility <> 0;") { s in
            var out: [String: PhotoFacts] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                guard let k = sqlite3_column_text(s, 0) else { continue }
                let things = sqlite3_column_text(s, 1).map { String(cString: $0).split(separator: " ").map(String.init) } ?? []
                let score = sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : sqlite3_column_double(s, 2)
                out[String(cString: k)] = PhotoFacts(things: things, score: score, utility: sqlite3_column_int(s, 3) != 0)
            }
            return out
        }
    }

    public func setSearch(key: String, stamp: String, words: String, things: [String] = [], score: Double? = nil, utility: Bool = false) throws {
        try withStatement("INSERT OR REPLACE INTO search (key, stamp, words, things, score, utility) VALUES (?, ?, ?, ?, ?, ?);", bind: { s in
            bindText(s, 1, key); bindText(s, 2, stamp); bindText(s, 3, words); bindText(s, 4, things.joined(separator: " "))
            if let score { sqlite3_bind_double(s, 5, score) } else { sqlite3_bind_null(s, 5) }
            sqlite3_bind_int(s, 6, utility ? 1 : 0)
        }) { s in
            guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
    }

    public func deleteSearch(keys: some Collection<String>) throws {
        for key in keys {
            try withStatement("DELETE FROM search WHERE key = ?;", bind: { bindText($0, 1, key) }) { _ = sqlite3_step($0) }
        }
    }

    // MARK: - Meta

    public func meta(_ key: String) -> String? {
        try? withReadStatement("SELECT value FROM meta WHERE key = ?;", bind: { bindText($0, 1, key) }) { s in
            sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_text(s, 0).map { String(cString: $0) } : nil
        }
    }

    public func setMeta(_ key: String, _ value: String?) {
        if let value {
            _ = try? withStatement("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);", bind: { bindText($0, 1, key); bindText($0, 2, value) }) { sqlite3_step($0) }
        } else {
            _ = try? withStatement("DELETE FROM meta WHERE key = ?;", bind: { bindText($0, 1, key) }) { sqlite3_step($0) }
        }
    }
}
