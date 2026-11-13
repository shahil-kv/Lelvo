import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Progress of one Takeout item. Settled values (done, duplicate, skipped) mean its zip can be forgotten.
public enum ImportStatus: String, Codable, Sendable {
    case pending, waitingForDetails, uploading, done, duplicate, skipped, failed
}

/// A zip or folder the user added. The bookmark is how this device finds it again; nothing here is uploaded.
public struct ImportSourceRecord: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var name: String
    public var bookmark: Data
    public var size: Int64
    public var addedAt: Date

    public init(id: String, kind: String, name: String, bookmark: Data, size: Int64, addedAt: Date) {
        self.id = id
        self.kind = kind
        self.name = name
        self.bookmark = bookmark
        self.size = size
        self.addedAt = addedAt
    }
}

extension LibraryStore {
    private static let importEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let importDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public func addImportSource(_ source: ImportSourceRecord) throws {
        try withStatement(
            "INSERT OR REPLACE INTO import_sources (id, kind, name, bookmark, size, added_at) VALUES (?, ?, ?, ?, ?, ?);",
            bind: { s in
                bindText(s, 1, source.id)
                bindText(s, 2, source.kind)
                bindText(s, 3, source.name)
                _ = source.bookmark.withUnsafeBytes {
                    sqlite3_bind_blob(s, 4, $0.baseAddress, Int32(source.bookmark.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(s, 5, source.size)
                sqlite3_bind_double(s, 6, source.addedAt.timeIntervalSince1970)
            }
        ) { s in
            guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError.sqlite("addImportSource failed") }
        }
    }

    public func importSources() throws -> [ImportSourceRecord] {
        try withReadStatement("SELECT id, kind, name, bookmark, size, added_at FROM import_sources ORDER BY added_at, id;") { s in
            var rows: [ImportSourceRecord] = []
            while sqlite3_step(s) == SQLITE_ROW {
                guard let id = sqlite3_column_text(s, 0).map({ String(cString: $0) }),
                      let kind = sqlite3_column_text(s, 1).map({ String(cString: $0) }),
                      let name = sqlite3_column_text(s, 2).map({ String(cString: $0) })
                else { continue }
                let blob = sqlite3_column_blob(s, 3)
                let bookmark = blob == nil ? Data() : Data(bytes: blob!, count: Int(sqlite3_column_bytes(s, 3)))
                rows.append(ImportSourceRecord(
                    id: id, kind: kind, name: name, bookmark: bookmark,
                    size: sqlite3_column_int64(s, 4),
                    addedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 5))))
            }
            return rows
        }
    }

    public func removeImportSource(id: String) throws {
        try withStatement("DELETE FROM import_sources WHERE id = ?;", bind: { bindText($0, 1, id) }) { s in
            guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError.sqlite("removeImportSource failed") }
        }
    }

    /// Re-planning (a later zip, a Live Photo pair) must not restart an item already uploading or done.
    /// A catalogue plan has no `dateUsed` or `uploadedSeparately`: send stores those after reading the file,
    /// and this write can land later, while the row is still pending. The JSON replace has to keep them.
    /// A finished row is not planned again, so a nil date written here would leave the photo off the undated list.
    public func upsertPlanned(_ items: [TakeoutPlannedItem]) throws {
        guard !items.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try inWriteTransaction {
            for var item in items {
                if item.dateUsed == nil || item.uploadedSeparately == nil {
                    let stored = try storedPlanned(key: item.key)
                    if item.dateUsed == nil { item.dateUsed = stored?.dateUsed }
                    if item.uploadedSeparately == nil { item.uploadedSeparately = stored?.uploadedSeparately }
                }
                let json = String(decoding: try Self.importEncoder.encode(item), as: UTF8.self)
                try withStatement(
                    """
                    INSERT INTO import_items (key, json, status, item_id, error, updated_at)
                    VALUES (?, ?, ?, NULL, NULL, ?)
                    ON CONFLICT(key) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at;
                    """,
                    bind: { s in
                        bindText(s, 1, item.key)
                        bindText(s, 2, json)
                        bindText(s, 3, ImportStatus.pending.rawValue)
                        sqlite3_bind_double(s, 4, now)
                    }
                ) { s in
                    guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError.sqlite("upsertPlanned failed") }
                }
            }
        }
    }

    /// Read on the writer, inside the upsert transaction, so a choice send committed after the catalogue
    /// read its snapshot is still here. Nil means the row is new, or send has not stored one yet.
    private func storedPlanned(key: String) throws -> TakeoutPlannedItem? {
        try withStatement(
            "SELECT json FROM import_items WHERE key = ? LIMIT 1;",
            bind: { bindText($0, 1, key) }
        ) { s in
            guard sqlite3_step(s) == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else { return nil }
            let json = Data(String(cString: text).utf8)
            return try? Self.importDecoder.decode(TakeoutPlannedItem.self, from: json)
        }
    }

    public func importItems(status: ImportStatus?) throws -> [(TakeoutPlannedItem, ImportStatus, String?)] {
        let sql = status == nil
            ? "SELECT json, status, item_id FROM import_items;"
            : "SELECT json, status, item_id FROM import_items WHERE status = ?;"
        return try withReadStatement(sql, bind: { s in
            if let status { bindText(s, 1, status.rawValue) }
        }) { s in
            var rows: [(TakeoutPlannedItem, ImportStatus, String?)] = []
            while sqlite3_step(s) == SQLITE_ROW {
                guard let json = sqlite3_column_text(s, 0).map({ String(cString: $0) }),
                      let item = try? Self.importDecoder.decode(TakeoutPlannedItem.self, from: Data(json.utf8)),
                      let raw = sqlite3_column_text(s, 1).map({ String(cString: $0) }),
                      let status = ImportStatus(rawValue: raw)
                else { continue }
                rows.append((item, status, sqlite3_column_text(s, 2).map { String(cString: $0) }))
            }
            return rows
        }
    }

    public func setImportStatus(key: String, status: ImportStatus, itemId: String?, error: String?) throws {
        try withStatement(
            "UPDATE import_items SET status = ?, item_id = ?, error = ?, updated_at = ? WHERE key = ?;",
            bind: { s in
                bindText(s, 1, status.rawValue)
                bindText(s, 2, itemId)
                bindText(s, 3, error)
                sqlite3_bind_double(s, 4, Date().timeIntervalSince1970)
                bindText(s, 5, key)
            }
        ) { s in
            guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError.sqlite("setImportStatus failed") }
        }
    }

    public func importCounts() throws -> [ImportStatus: Int] {
        try withReadStatement("SELECT status, COUNT(*) FROM import_items GROUP BY status;") { s in
            var counts: [ImportStatus: Int] = [:]
            while sqlite3_step(s) == SQLITE_ROW {
                if let raw = sqlite3_column_text(s, 0), let status = ImportStatus(rawValue: String(cString: raw)) {
                    counts[status] = Int(sqlite3_column_int64(s, 1))
                }
            }
            return counts
        }
    }

    /// True when every file from this zip or folder is done, a duplicate, or skipped — including album copies
    /// that belong to an item whose primary file is in another source.
    public func isSourceFinished(id: String) throws -> Bool {
        let settled: Set<ImportStatus> = [.done, .duplicate, .skipped]
        return try importItems(status: nil).allSatisfy { item, status, _ in
            !item.belongs(toSource: id) || settled.contains(status)
        }
    }

    public func clearImport() throws {
        // Same lock as the other writers: `exec` itself does not take it, and a wipe must not overlap an upsert.
        try inWriteTransaction {
            try exec("DELETE FROM import_items; DELETE FROM import_sources;")
        }
    }
}

extension TakeoutPlannedItem {
    fileprivate func belongs(toSource id: String) -> Bool {
        primary.sourceId == id
            || pairedVideo?.sourceId == id
            || edited?.sourceId == id
            || copies.contains { $0.sourceId == id }
    }
}
