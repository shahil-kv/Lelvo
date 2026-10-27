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
public final class LibraryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
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
        try exec("PRAGMA journal_mode=WAL;")
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
        try normalizeItemIds()
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
                if var twin = try self.item(id: item.id) {
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

    deinit { sqlite3_close(db) }

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

    private func withStatement<T>(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, _ body: (OpaquePointer?) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
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
        guard var item = try item(id: id) else { return nil }
        change(&item)
        try upsert(item)
        return item
    }

    public func item(id: String) throws -> MediaItem? {
        try withStatement("SELECT json FROM items WHERE id = ? LIMIT 1;", bind: { bindText($0, 1, id) }, readItems).first
    }

    /// Looks up by local identifier, including duplicate assets aliased to an item.
    public func item(localIdentifier: String) throws -> MediaItem? {
        if let direct = try withStatement("SELECT json FROM items WHERE local_id = ? LIMIT 1;", bind: { bindText($0, 1, localIdentifier) }, readItems).first {
            return direct
        }
        return try withStatement("SELECT items.json FROM aliases JOIN items ON items.id = aliases.item_id WHERE aliases.local_id = ? LIMIT 1;",
                                 bind: { bindText($0, 1, localIdentifier) }, readItems).first
    }

    /// Duplicate assets recorded by `addAlias`: (asset local identifier, item id).
    public func aliases() throws -> [(localIdentifier: String, itemId: String)] {
        try withStatement("SELECT local_id, item_id FROM aliases;") { s in
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
            result += try withStatement("SELECT json FROM items WHERE id IN (\(marks));", bind: { s in
                for (i, id) in batch.enumerated() { bindText(s, Int32(i + 1), id) }
            }, readItems)
        }
        return result
    }

    public func items(sha256: String) throws -> [MediaItem] {
        try withStatement("SELECT json FROM items WHERE sha256 = ?;", bind: { bindText($0, 1, sha256) }, readItems)
    }

    public func items(status: ItemStatus) throws -> [MediaItem] {
        try withStatement("SELECT json FROM items WHERE status = ? ORDER BY creation_date DESC;", bind: { bindText($0, 1, status.rawValue) }, readItems)
    }

    public func allItems() throws -> [MediaItem] {
        try withStatement("SELECT json FROM items ORDER BY creation_date DESC;", readItems)
    }

    /// All local identifiers the store knows, for fast scanning.
    public func knownLocalIdentifiers() throws -> Set<String> {
        try withStatement("SELECT local_id FROM items WHERE local_id IS NOT NULL UNION SELECT local_id FROM aliases;") { s in
            var set = Set<String>()
            while sqlite3_step(s) == SQLITE_ROW {
                if let c = sqlite3_column_text(s, 0) { set.insert(String(cString: c)) }
            }
            return set
        }
    }

    public func counts() throws -> [ItemStatus: Int] {
        try withStatement("SELECT status, COUNT(*) FROM items GROUP BY status;") { s in
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

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DELETE FROM items; DELETE FROM meta; DELETE FROM aliases;")
        notifyChanged(ids: nil)
    }

    // MARK: - Meta

    public func meta(_ key: String) -> String? {
        try? withStatement("SELECT value FROM meta WHERE key = ?;", bind: { bindText($0, 1, key) }) { s in
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
