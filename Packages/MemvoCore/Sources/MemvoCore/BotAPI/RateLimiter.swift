import Foundation

/// Exponential backoff with full jitter, honouring Telegram's `retry_after`.
public struct BackoffPolicy: Equatable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var maxAttempts: Int

    public init(baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 300, maxAttempts: Int = 8) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    public enum Decision: Equatable {
        case retry(after: TimeInterval)
        case giveUp
    }

    /// Upper bound of the delay before attempt number `attempt` (0-based).
    public func ceiling(forAttempt attempt: Int) -> TimeInterval {
        let exp = baseDelay * pow(2, Double(min(attempt, 20)))
        return min(maxDelay, exp)
    }

    /// `jitter` returns a value in 0...1; injectable for deterministic tests.
    public func decide(error: Error, attempt: Int, jitter: () -> Double = { Double.random(in: 0...1) }) -> Decision {
        if case TelegramError.rateLimited(let retryAfter) = error {
            // Telegram's instruction is authoritative; add a small cushion, never fewer than it asked.
            return attempt < maxAttempts * 2 ? .retry(after: TimeInterval(retryAfter) + 1) : .giveUp
        }
        let transient = (error as? TelegramError)?.isTransient ?? (error is URLError)
        guard transient, attempt < maxAttempts else { return .giveUp }
        let ceiling = ceiling(forAttempt: attempt)
        return .retry(after: max(baseDelay / 2, ceiling * (0.5 + 0.5 * jitter())))
    }
}

/// Spaces out sends to one chat (~1 message/second) and pauses everything after a 429.
public actor RateLimiter {
    public typealias Clock = @Sendable () -> Date

    private let minInterval: TimeInterval
    private let now: Clock
    private var nextAllowed: Date

    public init(minInterval: TimeInterval = 1.05, now: @escaping Clock = { Date() }) {
        self.minInterval = minInterval
        self.now = now
        self.nextAllowed = .distantPast
    }

    /// Reserves the next send slot and returns how long the caller must wait before using it.
    public func reserve() -> TimeInterval {
        let current = now()
        let slot = max(current, nextAllowed)
        nextAllowed = slot.addingTimeInterval(minInterval)
        return slot.timeIntervalSince(current)
    }

    /// Reserves `count` consecutive slots and returns their offsets from now
    /// (used to stagger background upload tasks with `earliestBeginDate`).
    public func reserve(count: Int) -> [TimeInterval] {
        (0..<count).map { _ in reserve() }
    }

    /// Called on HTTP 429: blocks all sends until `retryAfter` seconds have passed.
    public func penalize(retryAfter: TimeInterval) {
        let until = now().addingTimeInterval(retryAfter)
        if until > nextAllowed { nextAllowed = until }
    }

    public func wait() async {
        let delay = reserve()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}
