import Foundation

/// What the Backup screens say is left to do, in one place, so the iPhone and the Mac can't disagree with each other or
/// with what a backup really does.
public struct BackupCounts: Equatable, Sendable {
    /// Queued items this run will upload.
    public var activeQueue = 0
    /// Items a backup would pick up but hasn't queued: new photos, and queued ones waiting for "Back Up Now".
    public var notQueued = 0
    public var failed = 0
    /// Failed items a retry can help.
    public var retryable = 0

    /// Everything "Back Up Now" would upload.
    public var left: Int { activeQueue + notQueued }

    /// What automatic backup still has to do.
    public func pending(autoBackup: Bool) -> Int { activeQueue + (autoBackup ? notQueued : 0) }

    /// - Parameters:
    ///   - queued: items in the queue, uploading included.
    ///   - candidates: the local ids of photos the backup selection covers.
    ///   - known: local ids the index already has, in any state.
    ///   - offBackup: photos deleted from the backup on purpose, which a backup leaves alone.
    public static func compute(queued: [MediaItem], failed: [MediaItem], candidates: [String], known: Set<String>,
                               offBackup: Set<String>, autoBackup: Bool) -> BackupCounts {
        // Nothing can upload an incomplete item with no photo on this device: it belongs under Failed.
        let uploadable = queued.filter { !$0.isStrandedInCloud }
        let active = autoBackup ? uploadable.count : uploadable.filter { $0.chosen == true }.count
        var counts = BackupCounts()
        counts.activeQueue = active
        counts.notQueued = candidates.filter { !known.contains($0) && !offBackup.contains($0) }.count + (uploadable.count - active)
        let stranded = queued.filter(\.isStrandedInCloud).count
        counts.failed = failed.count + stranded
        counts.retryable = failed.filter { !$0.isStrandedInCloud }.count
        return counts
    }
}
