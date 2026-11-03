import Foundation

/// Keeps every upload within Telegram's limit of two at once, Recently Deleted notes included. A waiting note takes the
/// next free slot, so a long backup can't hold it back for hours.
public struct UploadSlots: Sendable {
    public let limit: Int
    private var used = 0
    private var noteWaiting = false

    public init(limit: Int) {
        self.limit = limit
    }

    public mutating func acquireForLane() -> Bool {
        guard used < limit, !noteWaiting else { return false }
        used += 1
        return true
    }

    /// Call again until it returns true: until then, the note counts as waiting.
    public mutating func acquireForNote() -> Bool {
        guard used < limit else {
            noteWaiting = true
            return false
        }
        noteWaiting = false
        used += 1
        return true
    }

    /// The note gave up (a deadline, or the task was cancelled). Without this the lanes would wait for it for ever.
    public mutating func stopWaitingForNote() {
        noteWaiting = false
    }

    public mutating func release() {
        used = max(0, used - 1)
    }
}
