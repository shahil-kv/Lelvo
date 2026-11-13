import Foundation

/// What to do with one Takeout entry, before anything is extracted. The importer asks this twice: once with the
/// facts it has up front (status, whether the zip is still there, free space), and again after the file is hashed
/// if a backed-up twin turns up.
public enum TakeoutImportStep {
    public enum Action: Equatable, Sendable {
        case upload
        case markDuplicate
        case waitForSource
        /// `needed` is how many more bytes have to be free before this file can be extracted.
        case stopForSpace(needed: Int64)
        case skip
    }

    /// A settled entry is left alone. A twin that isn't already mid-upload is a duplicate even when its zip is
    /// gone (the bytes are in the library). An upload that already started resumes, so a later twin doesn't
    /// abandon a half-sent item. Waiting entries stay put until their details arrive.
    public static func next(status: ImportStatus, existingBackedUpTwin: Bool, sourceAvailable: Bool,
                            freeBytes: Int64, neededBytes: Int64) -> Action {
        switch status {
        case .done, .duplicate, .skipped, .waitingForDetails:
            return .skip
        case .pending, .uploading, .failed:
            break
        }
        // A failed entry is tried again the next time the user starts the import. One pass doesn't retry it.
        if existingBackedUpTwin, status != .uploading {
            return .markDuplicate
        }
        if !sourceAvailable {
            return .waitForSource
        }
        if freeBytes < neededBytes {
            return .stopForSpace(needed: neededBytes - freeBytes)
        }
        return .upload
    }

    /// One lane while a phone backup is running, so the backup is never stuck behind the import. Both lanes otherwise.
    /// The two slots themselves still belong to `BackupEngine`.
    public static func laneCount(backupRunning: Bool) -> Int {
        backupRunning ? 1 : 2
    }

    /// Rows Start still has to upload. Failed counts: a run that only failed is not finished, so Start can retry
    /// them, the same as the next launch.
    public static func openCount(_ counts: [ImportStatus: Int]) -> Int {
        (counts[.pending] ?? 0) + (counts[.uploading] ?? 0) + (counts[.waitingForDetails] ?? 0) + (counts[.failed] ?? 0)
    }
}

extension TakeoutPlannedItem {
    /// Albums and a favourite from a later zip. A zip that doesn't mention one is not a removal.
    public func addingLateDetails(albums extra: [String], favorite: Bool) -> TakeoutPlannedItem {
        var item = self
        let known = Set(item.albums)
        let adding = extra.filter { !known.contains($0) }
        if !adding.isEmpty {
            item.albums = Array(known.union(adding)).sorted()
        }
        // A favourite-only sidecar has no date, so the upload still takes the date from the file.
        if favorite, item.sidecar?.favorite != true {
            var sidecar = item.sidecar ?? TakeoutSidecar()
            sidecar.favorite = true
            item.sidecar = sidecar
        }
        return item
    }
}

/// What to queue when a later zip adds an album or a favourite. Only additions: a Takeout that omits an album is not
/// an instruction to remove it, and a favourite is never cleared.
public enum TakeoutLateNotes {
    public static func additions(existingAlbums: [String], existingFavorite: Bool, albums: [String], favorite: Bool) -> [MetaLog.Key: Bool] {
        var have = Set(existingAlbums)
        for name in existingAlbums {
            if let trimmed = MetaLog.albumName(name) { have.insert(trimmed) }
        }
        var result: [MetaLog.Key: Bool] = [:]
        for album in albums {
            guard let name = MetaLog.albumName(album), !have.contains(name) else { continue }
            result[.album(name)] = true
            have.insert(name)
        }
        if favorite, !existingFavorite {
            result[.favorite] = true
        }
        return result
    }

    /// Writes a later zip's albums onto the library item and returns the note those additions need.
    /// The note is taken from the albums and favourite before the write. A confirmed part keeps the caption
    /// already in the channel, so a diff after the write is empty and a later scan drops the zip. With no
    /// confirmed part the first caption carries them, and the note is empty.
    public static func merge(albums: inout [String]?, favorite: inout Bool?, plannedAlbums: [String],
                             plannedFavorite: Bool, hasConfirmedPart: Bool) -> [MetaLog.Key: Bool] {
        let notes = hasConfirmedPart
            ? additions(existingAlbums: albums ?? [], existingFavorite: favorite == true,
                        albums: plannedAlbums, favorite: plannedFavorite)
            : [:]
        var names = Set(albums ?? [])
        names.formUnion(plannedAlbums)
        albums = names.isEmpty ? nil : names.sorted()
        if plannedFavorite { favorite = true }
        return notes
    }
}
