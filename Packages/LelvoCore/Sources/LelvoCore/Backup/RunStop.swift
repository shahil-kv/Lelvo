import Foundation

/// Why a whole backup run has to stop, as opposed to one file failing. Retrying the next file would fail the same way,
/// and a 40k queue would walk every item into Failed. The item that hit it goes back to waiting with no attempt used.
public enum RunStopCause: Equatable, Sendable {
    /// Telegram ended the session (signed out on another device, revoked, account deactivated).
    case sessionEnded
    /// The library channel can't be written to (deleted, left, no rights, banned).
    case channelUnavailable
    /// The device itself is out of space while exporting or encrypting a file.
    case deviceStorageFull

    public var message: String {
        switch self {
        case .sessionEnded:
            return "Telegram signed you out. Open Lelvo and sign in again. Your photos and the waiting list are kept."
        case .channelUnavailable:
            return "Lelvo can't write to your Telegram library channel. Check that you are still in it and can post, then back up again."
        case .deviceStorageFull:
            return "This device is out of storage. Free some space, then back up again. Nothing was lost."
        }
    }
}

public enum RunStopClassifier {
    /// Telegram errors that apply to every file, not just the one that was sent. Kept to messages that name the session
    /// or the channel: an unknown error stays a per-file failure.
    public static func cause(code: Int, message: String) -> RunStopCause? {
        let upper = message.uppercased()
        let channel = ["CHAT_WRITE_FORBIDDEN", "CHANNEL_PRIVATE", "CHAT_ADMIN_REQUIRED", "USER_BANNED_IN_CHANNEL",
                       "CHAT_RESTRICTED", "CHANNEL_INVALID"]
        if channel.contains(where: { upper.contains($0) }) { return .channelUnavailable }
        let session = ["SESSION_REVOKED", "AUTH_KEY_UNREGISTERED", "AUTH_KEY_INVALID", "USER_DEACTIVATED", "SESSION_EXPIRED"]
        if code == 401 || session.contains(where: { upper.contains($0) }) { return .sessionEnded }
        return nil
    }

    /// The reason on a file that alone doesn't fit while the device still has room.
    public static let fileDoesNotFitMessage = "Not enough space for this file."

    /// Out of space: the whole run stops only when the device is nearly full (`freeBytes` under `margin`); otherwise only
    /// that file fails, for good, so one huge file never blocks every photo behind it (I20). Unknown free space counts
    /// as room left.
    public static func diskFullStopsRun(freeBytes: Int64?, margin: Int64) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes < margin
    }

    /// `NSFileWriteOutOfSpaceError` (Cocoa 640) or `ENOSPC` (POSIX 28), also when wrapped as an underlying error.
    public static func isDiskFull(domain: String, code: Int) -> Bool {
        (domain == "NSCocoaErrorDomain" && code == 640) || (domain == "NSPOSIXErrorDomain" && code == 28)
    }
}
