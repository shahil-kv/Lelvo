import Foundation

/// Where a backup run came from.
public enum RunSource: String, Codable, Sendable { case app, continued, refresh, processing, shortcut }

/// One finished backup run. Counts only: no names, ids or places.
public struct RunRecord: Codable, Equatable, Sendable {
    public var source: RunSource
    public var startedAt: Date
    public var seconds: Double
    /// Items Telegram confirmed in this run.
    public var uploaded: Int
    /// Items still waiting when it ended.
    public var remaining: Int

    public init(source: RunSource, startedAt: Date, seconds: Double, uploaded: Int, remaining: Int) {
        self.source = source
        self.startedAt = startedAt
        self.seconds = seconds
        self.uploaded = uploaded
        self.remaining = remaining
    }
}

/// What Settings shows for the Camera automation.
public enum AutomationHealth: Equatable, Sendable {
    case notSetUp
    case working(lastRun: Date)
    case seemsOff(lastRun: Date)
}

public enum BackgroundRuns {
    /// Keeps the newest `limit` records.
    public static func appending(_ r: RunRecord, to list: [RunRecord], limit: Int = 200) -> [RunRecord] {
        let all = list + [r]
        return all.count > limit ? Array(all.suffix(limit)) : all
    }

    /// notSetUp: no `.shortcut` run ever. working: the last one is recent, or no photo was taken since it.
    /// seemsOff: otherwise.
    public static func automationHealth(_ list: [RunRecord], newestPhotoDate: Date?, now: Date,
                                        staleAfter: TimeInterval = 7 * 86_400) -> AutomationHealth {
        guard let last = list.filter({ $0.source == .shortcut }).map(\.startedAt).max() else { return .notSetUp }
        if now.timeIntervalSince(last) <= staleAfter { return .working(lastRun: last) }
        if let newest = newestPhotoDate, newest > last { return .seemsOff(lastRun: last) }
        return .working(lastRun: last)
    }

    /// Stuck reminder: nil if nothing is waiting. Otherwise the date the next reminder may fire: 2 days after the
    /// last upload, then 4, then 8 (and 8 after that). `remindersSent` resets to 0 after any run that uploaded.
    public static func nextReminder(lastUpload: Date?, waiting: Int, remindersSent: Int, now: Date) -> Date? {
        guard waiting > 0 else { return nil }
        let days = [2, 4, 8]
        // Reminders are spaced from the last upload: 2 days, then 4 more, then 8 more.
        let offset = (0...max(remindersSent, 0)).reduce(0) { $0 + days[min($1, days.count - 1)] }
        return (lastUpload ?? now).addingTimeInterval(TimeInterval(offset) * 86_400)
    }

    /// Runs between 22:00 and 07:00 local time count as overnight.
    public static func isOvernight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 7
    }

    /// "312 photos and 4 videos backed up overnight." Nil when nothing was uploaded.
    public static func summaryText(photos: Int, videos: Int, overnight: Bool) -> String? {
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " and ") + " backed up" + (overnight ? " overnight." : ".")
    }
}
