import Foundation

/// The date written on an imported item. Google's JSON wins, then a date read from the file, then the zip
/// entry's modified date once every file is here or this upload already started. Only that last one is listed
/// as imported without a date from Google: a date from the file is still a capture date.
public enum TakeoutDateChoice {
    public enum Source: String, Codable, Sendable, Equatable {
        case google
        case file
        case zipModified
    }

    public struct Result: Equatable, Sendable {
        public var date: Date?
        public var source: Source
    }

    public static func choose(google: Date?, file: Date?, zipModified: Date?,
                              allFilesAdded: Bool, alreadyUploading: Bool) -> Result? {
        if let google {
            return Result(date: google, source: .google)
        }
        if let file {
            return Result(date: file, source: .file)
        }
        if allFilesAdded || alreadyUploading {
            return Result(date: zipModified, source: .zipModified)
        }
        return nil
    }

    public static func importedWithoutGoogleDate(_ source: Source?) -> Bool {
        source == .zipModified
    }
}

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

/// What to do with a paired edit or Live Photo video once the original's SHA-256 is already a backed-up twin.
/// The original is a duplicate either way. These files stay off that twin: writing them on would replace its caption.
public enum TakeoutDuplicateExtras {
    public enum Action: Equatable, Sendable {
        /// The edit, as its own photo.
        case uploadOwnPhoto
        /// The Live Photo video, as its own video.
        case uploadOwnVideo
        /// The file is already on the twin, or already backed up as its own item.
        case alreadyInLibrary
    }

    public struct Result: Equatable, Sendable {
        public var edit: Action?
        public var pairedVideo: Action?

        /// True when nothing here still has to be uploaded, so the import row may become `.duplicate`.
        public var mayMarkDuplicate: Bool {
            [edit, pairedVideo].compactMap { $0 }.allSatisfy { $0 == .alreadyInLibrary }
        }

        public init(edit: Action?, pairedVideo: Action?) {
            self.edit = edit
            self.pairedVideo = pairedVideo
        }
    }

    /// `backedUpOriginalHashes` are SHA-256 values of items already `.backedUp` (the original file, not a role).
    public static func decide(editedHash: String?, pairedHash: String?, twin: MediaItem,
                              backedUpOriginalHashes: Set<String>) -> Result {
        Result(
            edit: editAction(editedHash, twin: twin, backedUpOriginalHashes: backedUpOriginalHashes),
            pairedVideo: videoAction(pairedHash, twin: twin, backedUpOriginalHashes: backedUpOriginalHashes))
    }

    /// A different crop is its own photo. The same edit already on the twin, or the same bytes already backed up,
    /// is not uploaded again and is not attached to the twin.
    private static func editAction(_ hash: String?, twin: MediaItem, backedUpOriginalHashes: Set<String>) -> Action? {
        guard let hash else { return nil }
        if Deduplicator.isSamePhoto(editHash: hash, as: twin) { return .alreadyInLibrary }
        if backedUpOriginalHashes.contains(hash) { return .alreadyInLibrary }
        return .uploadOwnPhoto
    }

    /// A Live Photo video the twin does not already have as `pv` is its own video, unless those bytes are already
    /// backed up on their own.
    private static func videoAction(_ hash: String?, twin: MediaItem, backedUpOriginalHashes: Set<String>) -> Action? {
        guard let hash else { return nil }
        if twin.roleHashes?["pv"] == hash { return .alreadyInLibrary }
        if backedUpOriginalHashes.contains(hash) { return .alreadyInLibrary }
        return .uploadOwnVideo
    }
}

extension TakeoutPlannedItem {
    /// A later catalogue is built before the file is read, so it doesn't know which date was written.
    public func keepingDateUsed(_ previous: TakeoutDateChoice.Source?) -> TakeoutPlannedItem {
        guard dateUsed == nil, let previous else { return self }
        var item = self
        item.dateUsed = previous
        return item
    }

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

    /// Files from this plan that were uploaded as their own items. Empty until that happens, so an edit or Live
    /// Photo video that stayed attached to its original is not listed as separate.
    public func entriesUploadedSeparately() -> [TakeoutSourceEntry] {
        let names = Set(uploadedSeparately ?? [])
        guard !names.isEmpty else { return [] }
        return [edited, pairedVideo].compactMap { $0 }.filter { names.contains(TakeoutMatcher.fileName($0.entry.path)) }
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
