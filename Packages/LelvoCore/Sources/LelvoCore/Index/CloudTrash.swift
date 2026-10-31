import Foundation

/// "Recently Deleted" for cloud items: deleting from the cloud only marks the item, and its Telegram messages are
/// deleted after `retention` (or when the user empties it). The mark lives in the local index only; if the index
/// is lost, the next scan brings the items back, which errs towards keeping photos.
public enum CloudTrash {
    public static let retention: TimeInterval = 30 * 24 * 3600

    public static func trash(_ item: inout MediaItem, now: Date = Date()) {
        guard item.status == .backedUp else { return }
        item.status = .trashed
        item.trashedAt = now
    }

    public static func recover(_ item: inout MediaItem) {
        guard item.status == .trashed else { return }
        item.status = item.isFullyUploaded ? .backedUp : .failed
        item.trashedAt = nil
    }

    /// Days until the messages are deleted, rounded up like Photos' Recently Deleted: 30 right after deleting,
    /// 1 on the last day.
    public static func daysLeft(_ item: MediaItem, now: Date = Date()) -> Int {
        guard let at = item.trashedAt else { return Int(retention / 86400) }
        return max(0, Int((at.addingTimeInterval(retention).timeIntervalSince(now) / 86400).rounded(.up)))
    }

    public static func isExpired(_ item: MediaItem, now: Date = Date()) -> Bool {
        guard item.status == .trashed else { return false }
        // A missing date (shouldn't happen) never expires: keep data when in doubt.
        guard let at = item.trashedAt else { return false }
        return now >= at.addingTimeInterval(retention)
    }
}
