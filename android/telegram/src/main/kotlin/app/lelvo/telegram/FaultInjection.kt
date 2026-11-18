package app.lelvo.telegram

import app.lelvo.core.support.AppLog
import kotlinx.coroutines.delay

/**
 * Debug-only faults for repeatable tests of Telegram's limits and bad networks (test plan A2), like iOS's launch
 * arguments. Set from a debug intent: `adb shell am start -n app.lelvo.android/.MainActivity --es lelvo.faults "flood 3 30"`
 * (also `fail 3 2`, `offline 3 60`, `slow 2000`, `off`). Counts every file send of this process from 1 and fails the
 * chosen ones before anything reaches Telegram, so no message is created. Never set in release builds.
 */
object FaultInjection {
    @Volatile var spec: String? = null
        set(value) { field = value?.takeUnless { it == "off" }; sends = 0; offlineUntil = 0; AppLog.info("QA: faults ${field ?: "off"}") }
    private var sends = 0
    private var offlineUntil = 0L

    suspend fun beforeSend() {
        val parts = spec?.split(' ')?.mapNotNull { it.toIntOrNull() ?: it.takeIf { w -> w.isNotBlank() } } ?: return
        val kind = parts.firstOrNull() as? String ?: return
        val a = parts.getOrNull(1) as? Int ?: return
        val b = parts.getOrNull(2) as? Int
        if (kind == "slow") { delay(a.toLong()); return }
        val n = synchronized(this) { ++sends }
        when (kind) {
            "flood" -> if (n == a) {
                val s = b ?: 30
                AppLog.info("QA: injected FLOOD_WAIT $s s on send $n")
                throw TelegramException(429, "Too Many Requests: retry after $s (FLOOD_WAIT_$s)")
            }
            "fail" -> if (n >= a && n < a + (b ?: 1)) {
                AppLog.info("QA: injected dropped connection on send $n")
                throw java.io.IOException("QA: connection dropped")
            }
            "offline" -> if (n >= a) {
                val until = synchronized(this) { if (offlineUntil == 0L) offlineUntil = System.currentTimeMillis() + (b ?: 60) * 1000L; offlineUntil }
                if (System.currentTimeMillis() < until) {
                    AppLog.info("QA: injected offline on send $n")
                    throw java.io.IOException("QA: offline")
                }
            }
        }
    }
}
