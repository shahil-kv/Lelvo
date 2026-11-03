import Foundation

/// "Recently Deleted" for cloud items: deleting from the cloud only marks the item, and its Telegram messages are
/// deleted after `retention` (or when the user empties it). Notes in the channel share the mark between devices
/// (`TrashLog`); if a note is missed, the item stays a normal backup, which errs towards keeping photos.
public enum CloudTrash {
    public static let retention: TimeInterval = {
        #if DEBUG
        // `-TestTrashRetentionSeconds <n>`: tries the 30-day cleanup and its notes without waiting 30 days.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-TestTrashRetentionSeconds"), i + 1 < args.count, let seconds = TimeInterval(args[i + 1]), seconds > 0 { return seconds }
        #endif
        return 30 * 24 * 3600
    }()

    public static func trash(_ item: inout MediaItem, now: Date = Date()) {
        guard item.status == .backedUp || item.isStrandedInCloud else { return }
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

    /// The date to record for a delete. A device clock set behind would start the 30 days in the past, so the later of
    /// the two clocks wins: a wrong clock can only keep an item longer.
    public static func deletedAt(device: Date, telegram: Date?) -> Date {
        telegram.map { max($0, device) } ?? device
    }

    /// The time to test expiry against: the earlier clock, so neither can delete early alone. Nil without Telegram's
    /// time, and nothing expires then: a device clock set ahead must not be able to delete anything.
    public static func expiryClock(device: Date, telegram: Date?) -> Date? {
        telegram.map { min($0, device) }
    }

    /// Message ids in one delete request; Telegram takes up to 100 per call in a channel.
    public static let maxMessagesPerDelete = 100

    /// Groups items for deletion so 50 photos take one request instead of 50. An item's messages stay together, so a
    /// failed request can't leave it half deleted; an item with more messages than the limit goes alone.
    public static func deleteBatches(_ items: [MediaItem]) -> [[MediaItem]] {
        var batches: [[MediaItem]] = []
        var current: [MediaItem] = []
        var count = 0
        for item in items {
            let messages = item.allMessageIds.count
            if !current.isEmpty, count + messages > maxMessagesPerDelete {
                batches.append(current)
                current = []
                count = 0
            }
            current.append(item)
            count += messages
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
