import Foundation

/// Upload job state machine (docs/ARCHITECTURE.md "Job queue state machine").
public enum JobState: String, Codable, Sendable, CaseIterable {
    case pending, uploading, verified, failed
}

public struct JobStatus: Codable, Equatable, Sendable {
    public var state: JobState
    public var attempts: Int
    public var lastError: String?
    /// Don't start before this time (FLOOD_WAIT / backoff).
    public var notBefore: Date?

    public init(state: JobState = .pending, attempts: Int = 0, lastError: String? = nil, notBefore: Date? = nil) {
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.notBefore = notBefore
    }

    public func isRunnable(at now: Date) -> Bool {
        state == .pending && (notBefore.map { $0 <= now } ?? true)
    }
}

public enum JobEvent: Equatable, Sendable {
    case start
    /// Telegram confirmed the message; `sizeMatches` compares the stored document size.
    case sent(sizeMatches: Bool)
    case floodWait(seconds: Int)
    case error(reason: String, transient: Bool)
    /// The app was killed or the task expired mid-upload.
    case interrupted
    case retry
}

public enum JobMachine {
    public static let maxAttempts = 5

    public static func reduce(_ job: JobStatus, _ event: JobEvent, now: Date = Date(),
                              backoff: BackoffPolicy = BackoffPolicy(baseDelay: 5, maxDelay: 30 * 60, maxAttempts: maxAttempts)) -> JobStatus {
        var j = job
        switch (job.state, event) {
        case (.pending, .start):
            j.state = .uploading
            j.notBefore = nil
        case (.uploading, .sent(true)):
            j.state = .verified
            j.lastError = nil
            j.notBefore = nil
        case (.uploading, .sent(false)):
            j.state = .failed
            j.attempts += 1
            j.lastError = "Telegram stored a file with a different size than was uploaded."
        case (.uploading, .floodWait(let s)):
            // Telegram's instruction, not our failure: wait and try again without counting an attempt.
            j.state = .pending
            j.notBefore = now.addingTimeInterval(TimeInterval(max(1, s)))
            j.lastError = "Telegram asked to wait \(s) s (FLOOD_WAIT)."
        case (.uploading, .error(let reason, let transient)):
            j.attempts += 1
            j.lastError = reason
            if transient && j.attempts < maxAttempts {
                j.state = .pending
                j.notBefore = now.addingTimeInterval(backoff.ceiling(forAttempt: j.attempts - 1))
            } else {
                j.state = .failed
            }
        case (.uploading, .interrupted):
            j.state = .pending
        case (.failed, .retry):
            j.state = .pending
            j.attempts = 0
            j.notBefore = nil
            j.lastError = nil
        default:
            break // Invalid transitions are ignored; verified is terminal.
        }
        return j
    }
}

/// Classifies TDLib errors (code + message).
public enum TelegramErrorKind: Equatable, Sendable {
    case floodWait(seconds: Int)
    case transient
    case auth
    case permanent
}

public enum TelegramErrorClassifier {
    public static func classify(code: Int, message: String) -> TelegramErrorKind {
        if let s = floodWaitSeconds(message), code == 429 || message.uppercased().contains("FLOOD") || message.contains("retry after") {
            return .floodWait(seconds: s)
        }
        if code == 429 { return .floodWait(seconds: 5) }
        if code == 401 || message.contains("AUTH_KEY") || message.contains("SESSION_REVOKED") || message.contains("Unauthorized") {
            return .auth
        }
        if code >= 500 || code == 406 && message.contains("TIMEOUT") || code == -1 { return .transient }
        let upper = message.uppercased()
        if upper.contains("NETWORK") || upper.contains("TIMEOUT") || upper.contains("CONNECTION") || upper.contains("FILE_PART") && upper.contains("MISSING") {
            return .transient
        }
        return .permanent
    }

    /// Extracts X from "FLOOD_WAIT_X", "FLOOD_PREMIUM_WAIT_X" or "retry after X".
    public static func floodWaitSeconds(_ message: String) -> Int? {
        let patterns = [#"FLOOD(?:_PREMIUM)?_WAIT_(\d+)"#, #"retry after (\d+)"#]
        for p in patterns {
            if let r = message.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let digits = message[r].filter(\.isNumber)
                if let n = Int(digits) { return n }
            }
        }
        return nil
    }
}
