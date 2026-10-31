import Foundation

/// Upload speed over the last few seconds, for a "time left" estimate. Telegram's speed limit for accounts without
/// Premium can make a big video take many minutes; an estimate shows it's slow rather than stuck.
public struct TransferRate: Sendable {
    /// Speed is measured over this much recent history, so it follows a speed limit that starts mid-file.
    public static let window: TimeInterval = 20
    /// Shorter than this and the first bursts make the estimate jump around.
    public static let minimumSpan: TimeInterval = 3

    private var samples: [(at: Date, bytes: Int64)] = []

    public init() {}

    /// Bytes sent so far for the current file. Going backwards means a new file (or a retry): start over.
    public mutating func record(_ bytes: Int64, at now: Date) {
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.window }
    }

    /// Bytes per second, or nil until there's enough history.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.minimumSpan else { return nil }
        return Double(last.bytes - first.bytes) / span
    }

    /// Seconds until `total` bytes are sent at the recent speed; nil when unknown or not moving.
    public func secondsLeft(total: Int64) -> Int? {
        guard let rate = bytesPerSecond, rate > 0, let sent = samples.last?.bytes, total > sent else { return nil }
        return Int((Double(total - sent) / rate).rounded(.up))
    }
}
