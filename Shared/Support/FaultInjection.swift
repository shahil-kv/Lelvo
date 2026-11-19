#if DEBUG
import Foundation

/// Debug-only faults for repeatable tests of Telegram's limits and bad networks (test plan A2: T.1, 1.10, 1.11, 7.3, L.4).
/// Counts every file send of this process (photo parts and notes), starting at 1, and fails chosen ones *before*
/// anything reaches Telegram, so no message is created and nothing in the channel changes.
///   -QAFloodOnSend <n> <s>    send n gets FLOOD_WAIT of s seconds (as Telegram's 429 "FLOOD_WAIT_s")
///   -QAFailSend <n> [count]   sends n…n+count-1 fail as a dropped connection (default count 1)
///   -QAOfflineFor <n> <s>     from send n, every send fails for s seconds, like airplane mode
///   -QASlowSend <ms>          each send waits ms first, so a kill or pause lands mid-run
///   -QARevokeOnSend <n>       from send n, every send fails as Telegram's 401 SESSION_REVOKED (run must stop, nothing marked failed)
///   -QAChannelGoneOnSend <n>  from send n, every send fails as 403 CHAT_WRITE_FORBIDDEN
///   -QADiskFullOnSend <n>     from send n, every send fails as the OS's out-of-space error (Cocoa 640)
enum FaultInjection {
    private static let args = ProcessInfo.processInfo.arguments
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sends = 0
    nonisolated(unsafe) private static var offlineUntil: Date?

    private static func value(_ name: String, _ offset: Int = 1) -> Int? {
        args.firstIndex(of: name).flatMap { args.indices.contains($0 + offset) ? Int(args[$0 + offset]) : nil }
    }

    static var isActive: Bool { args.contains { $0.hasPrefix("-QAFlood") || $0.hasPrefix("-QAFail") || $0.hasPrefix("-QAOffline") || $0.hasPrefix("-QARevoke") || $0.hasPrefix("-QAChannelGone") || $0.hasPrefix("-QADiskFull") || $0 == "-QASlowSend" } }

    /// A real full disk also leaves little free space, which is what lets the error stop the run (BackupEngine).
    static var fakesDeviceFull: Bool { args.contains("-QADiskFullOnSend") }

    /// Called at the top of every file send. Throws the injected error, or returns after any injected delay.
    static func beforeSend() async throws {
        guard isActive else { return }
        if let ms = value("-QASlowSend") { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
        let n: Int = lock.withLock { sends += 1; return sends }
        if let at = value("-QAFloodOnSend"), n == at {
            let s = value("-QAFloodOnSend", 2) ?? 30
            appLog("QA: injected FLOOD_WAIT \(s) s on send \(n)")
            throw TDServiceError.telegram(code: 429, message: "Too Many Requests: retry after \(s) (FLOOD_WAIT_\(s))")
        }
        if let at = value("-QAFailSend"), n >= at, n < at + (value("-QAFailSend", 2) ?? 1) {
            appLog("QA: injected dropped connection on send \(n)")
            throw TDServiceError.notReady
        }
        if let at = value("-QARevokeOnSend"), n >= at {
            appLog("QA: injected session revoked on send \(n)")
            throw TDServiceError.telegram(code: 401, message: "SESSION_REVOKED")
        }
        if let at = value("-QAChannelGoneOnSend"), n >= at {
            appLog("QA: injected channel gone on send \(n)")
            throw TDServiceError.telegram(code: 403, message: "CHAT_WRITE_FORBIDDEN")
        }
        if let at = value("-QADiskFullOnSend"), n >= at {
            appLog("QA: injected disk full on send \(n)")
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        if let at = value("-QAOfflineFor"), n >= at {
            let until: Date = lock.withLock {
                if offlineUntil == nil { offlineUntil = Date().addingTimeInterval(TimeInterval(value("-QAOfflineFor", 2) ?? 60)) }
                return offlineUntil!
            }
            if Date() < until {
                appLog("QA: injected offline on send \(n)")
                throw TDServiceError.notReady
            }
        }
    }
}
#endif
