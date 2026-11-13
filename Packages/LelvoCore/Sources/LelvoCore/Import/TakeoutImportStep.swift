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
}
