import Foundation

/// Tells a Telegram session ended outside this app (removed in Telegram → Devices) from one this app closed. TDLib reports
/// "logging out" and then "closed" for both; a plain restart reports "closed" without logging out.
public struct SessionWatch: Sendable {
    private var sawLoggingOut = false
    private var ownSignOutStarted = false

    public init() {}

    public mutating func ready() {
        sawLoggingOut = false
        ownSignOutStarted = false
    }

    public mutating func ownSignOut() { ownSignOutStarted = true }

    public mutating func loggingOut() { sawLoggingOut = true }

    /// Whether the session that just closed was ended from outside.
    public mutating func closed() -> Bool {
        defer { ready() }
        return sawLoggingOut && !ownSignOutStarted
    }
}
