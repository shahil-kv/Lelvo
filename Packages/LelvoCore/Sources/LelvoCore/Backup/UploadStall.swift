import Foundation

/// Tells a slow upload from a stuck one. TDLib reports every piece it uploads; when those reports stop for
/// `timeout`, the send is waiting on a connection that won't come back by itself (TDLib never fails it), and the
/// backup would show the same "25 MB of 80 MB" forever. A slow upload, including Telegram's speed limit for accounts
/// without Premium, still moves and is never called stuck.
public struct UploadStall: Sendable {
    public static let defaultTimeout: TimeInterval = 180

    public let timeout: TimeInterval
    public private(set) var sent: Int64 = -1
    public private(set) var movedAt: Date

    public init(startedAt: Date, timeout: TimeInterval = UploadStall.defaultTimeout) {
        self.timeout = timeout
        self.movedAt = startedAt
    }

    /// A progress report from TDLib. Only new bytes count as moving: TDLib repeats a file's state when other fields change.
    public mutating func record(sent: Int64, at now: Date) {
        guard sent != self.sent else { return }
        self.sent = sent
        movedAt = now
    }

    /// Gives the upload another full `timeout`, e.g. after cancelling it failed.
    public mutating func restart(at now: Date) {
        movedAt = now
    }

    public func isStalled(at now: Date) -> Bool {
        now.timeIntervalSince(movedAt) >= timeout
    }

    /// The watchdog's periodic look. A gap of more than `suspendGap` since its last look means iOS suspended the app
    /// (backgrounded, then reopened): TDLib was frozen too, so that time doesn't count against the upload.
    public static let suspendGap: TimeInterval = 30
    private var checkedAt: Date?

    public mutating func check(at now: Date) -> Bool {
        if let checkedAt, now.timeIntervalSince(checkedAt) > Self.suspendGap { movedAt = now }
        checkedAt = now
        return isStalled(at: now)
    }
}
