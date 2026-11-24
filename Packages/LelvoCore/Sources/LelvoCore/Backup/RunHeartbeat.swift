import Foundation

/// Tells a backup run that iOS froze from one that is only slow. iOS suspends the app in the background when no
/// background time covers the run; the upload's connection is gone when it wakes, and the stall watchdog doesn't count
/// suspended time, so the run never ends by itself. Seen on the iPhone: one such run blocked every background run for
/// 1.5 hours, each of them giving up at once because "a backup is already running".
///
/// The run beats every few seconds while the process is awake. A gap far longer than that means the process was
/// suspended. Frozen = suspended since the run last moved, and still not moving `frozenAfter` seconds after waking.
public struct RunHeartbeat: Sendable {
    public static let suspendGap: TimeInterval = 30
    /// Short, because a background refresh has only about 30 s: a live upload reconnects and moves within a few seconds.
    public static let frozenAfter: TimeInterval = 12

    public private(set) var movedAt: Date
    private var beatAt: Date
    /// When the process woke from a suspension that came after the run last moved.
    private var wokeAt: Date?

    public init(startedAt: Date) {
        movedAt = startedAt
        beatAt = startedAt
    }

    /// Upload bytes went out, or an item finished.
    public mutating func moved(at now: Date) {
        movedAt = now
        beatAt = now
        wokeAt = nil
    }

    /// The run's periodic tick.
    public mutating func beat(at now: Date) {
        if wokeAt == nil, now.timeIntervalSince(beatAt) > Self.suspendGap { wokeAt = now }
        beatAt = now
    }

    /// Suspended since the run last moved: it may be frozen, wait `frozenAfter` to know.
    public var wasSuspended: Bool { wokeAt != nil }

    public func isFrozen(at now: Date) -> Bool {
        wokeAt.map { now.timeIntervalSince($0) > Self.frozenAfter } ?? false
    }
}
