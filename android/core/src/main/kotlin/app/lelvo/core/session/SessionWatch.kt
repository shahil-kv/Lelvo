package app.lelvo.core.session

/**
 * Tells a Telegram session ended outside this app (removed in Telegram → Devices) from one this app closed. TDLib
 * reports "logging out" and then "closed" for both; a plain restart reports "closed" without logging out.
 * Same rules as the iOS `SessionWatch`.
 */
class SessionWatch {
    private var sawLoggingOut = false
    private var ownSignOutStarted = false

    fun ready() {
        sawLoggingOut = false
        ownSignOutStarted = false
    }

    fun ownSignOut() { ownSignOutStarted = true }

    fun loggingOut() { sawLoggingOut = true }

    /** Whether the session that just closed was ended from outside. */
    fun closed(): Boolean {
        val ended = sawLoggingOut && !ownSignOutStarted
        ready()
        return ended
    }
}
