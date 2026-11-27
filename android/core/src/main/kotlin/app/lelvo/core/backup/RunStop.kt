package app.lelvo.core.backup

/**
 * Why a whole backup run has to stop, as opposed to one file failing (iOS `RunStopCause`). Retrying the next file would
 * fail the same way, and a 40k queue would walk every item into Failed. The item that hit it goes back to waiting with no
 * attempt used.
 */
enum class RunStopCause(val message: String, val actionLabel: String?) {
    /** Telegram ended the session (signed out on another device, revoked, account deactivated). */
    SessionEnded("Telegram signed you out. Open Lelvo and sign in again. Your photos and the waiting list are kept.", "Sign in again"),

    /** The library channel can't be written to (deleted, left, no rights, banned). */
    ChannelUnavailable("Lelvo can't write to your Telegram library channel. Check that you are still in it and can post, then back up again.", "Open library settings"),

    /** The device itself is out of space while reading or encrypting a file. */
    DeviceStorageFull("This device is out of storage. Free some space, then back up again. Nothing was lost.", null),
}

object RunStopClassifier {
    private val channel = listOf(
        "CHAT_WRITE_FORBIDDEN", "CHANNEL_PRIVATE", "CHAT_ADMIN_REQUIRED", "USER_BANNED_IN_CHANNEL", "CHAT_RESTRICTED", "CHANNEL_INVALID",
    )
    private val session = listOf("SESSION_REVOKED", "AUTH_KEY_UNREGISTERED", "AUTH_KEY_INVALID", "USER_DEACTIVATED", "SESSION_EXPIRED")

    /** Telegram errors that apply to every file. An unknown error stays a per-file failure. */
    fun cause(code: Int, message: String): RunStopCause? {
        val upper = message.uppercase()
        if (channel.any { upper.contains(it) }) return RunStopCause.ChannelUnavailable
        if (code == 401 || session.any { upper.contains(it) }) return RunStopCause.SessionEnded
        return null
    }

    /** The reason on a file that alone doesn't fit while the device still has room (iOS `fileDoesNotFitMessage`). */
    const val FILE_DOES_NOT_FIT = "Not enough space for this file."

    /**
     * Out of space: the whole run stops only when the device is nearly full ([freeBytes] under [margin]); otherwise only
     * that file fails, for good, so one huge file never blocks every photo behind it (I20, the iPhone rule). Unknown
     * free space counts as room left.
     */
    fun diskFullStopsRun(freeBytes: Long?, margin: Long): Boolean = freeBytes != null && freeBytes < margin

    /** POSIX `ENOSPC`. */
    const val ENOSPC = 28

    /** `ErrnoException.errno == ENOSPC`, or the JVM's text for it ("No space left on device"). */
    fun isDiskFull(errno: Int?, message: String?): Boolean =
        errno == ENOSPC || message?.contains("No space left on device", ignoreCase = true) == true ||
            message?.contains("ENOSPC") == true
}
