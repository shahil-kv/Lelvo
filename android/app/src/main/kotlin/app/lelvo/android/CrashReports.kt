package app.lelvo.android

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import app.lelvo.core.support.AppLog

/**
 * Why Lelvo last stopped, written to the log the user can share from Settings → Logs. Lelvo has no crash reporting
 * service (nothing leaves the phone), so a crash, a freeze ("isn't responding") or Android ending it for memory was
 * invisible: the user only saw the app close.
 *
 * Only exception classes and stack frames are written, never exception messages, which can carry file ids.
 */
object CrashReports {
    fun install(context: Context) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                AppLog.error("Crash on thread ${thread.name}:\n${frames(error)}")
                AppLog.flush()
            }
            previous?.uncaughtException(thread, error)
        }
        Thread { runCatching { logLastExits(context) } }.start()
    }

    /** Android 11+ keeps why the app's last processes ended, including freezes and memory kills a handler never sees. */
    private fun logLastExits(context: Context) {
        if (Build.VERSION.SDK_INT < 30) return
        val prefs = context.getSharedPreferences("crash-reports", Context.MODE_PRIVATE)
        val seen = prefs.getLong("seen", 0)
        val am = context.getSystemService(ActivityManager::class.java) ?: return
        val exits = am.getHistoricalProcessExitReasons(context.packageName, 0, 10).filter { it.timestamp > seen }
        for (exit in exits.sortedBy { it.timestamp }) {
            val reason = reasonName(exit.reason)
            // Ordinary ends (the user swiped it away, Android freed memory in the background) aren't problems.
            val problem = exit.reason in setOf(ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE,
                ApplicationExitInfo.REASON_ANR, ApplicationExitInfo.REASON_LOW_MEMORY, ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
                ApplicationExitInfo.REASON_INITIALIZATION_FAILURE)
            val line = "Last exit at ${java.time.Instant.ofEpochMilli(exit.timestamp)}: $reason, " +
                "${if (exit.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND) "on screen" else "in the background"}, " +
                "memory ${exit.pss / 1024} MB (PSS), ${exit.rss / 1024} MB (RSS)"
            if (!problem) { AppLog.info(line); continue }
            val trace = if (exit.reason == ApplicationExitInfo.REASON_ANR) anrMainThread(exit) else null
            AppLog.error(line + (trace?.let { "\n$it" } ?: ""))
        }
        exits.maxOfOrNull { it.timestamp }?.let { prefs.edit().putLong("seen", it).apply() }
    }

    /** The main thread's stack from Android's freeze report: what Lelvo was doing when it stopped answering. */
    private fun anrMainThread(exit: ApplicationExitInfo): String? = runCatching {
        exit.traceInputStream?.bufferedReader()?.use { r ->
            val lines = r.readLines()
            val start = lines.indexOfFirst { it.startsWith("\"main\"") }
            if (start < 0) return@use null
            lines.drop(start).takeWhile { it.isNotBlank() }.take(40)
                .filter { it.trimStart().startsWith("at ") || it.startsWith("\"main\"") || it.trimStart().startsWith("- ") }
                .joinToString("\n")
        }
    }.getOrNull()

    private fun frames(error: Throwable): String {
        val out = StringBuilder()
        var e: Throwable? = error
        var depth = 0
        while (e != null && depth < 4) {
            out.append(if (depth == 0) "" else "Caused by: ").append(e.javaClass.name).append('\n')
            e.stackTrace.take(25).forEach { out.append("  at ").append(it).append('\n') }
            e = e.cause.takeIf { it !== e }
            depth++
        }
        return out.toString().trimEnd()
    }

    private fun reasonName(reason: Int) = when (reason) {
        ApplicationExitInfo.REASON_CRASH -> "crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
        ApplicationExitInfo.REASON_ANR -> "not responding (frozen)"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "ended for low memory"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "ended for using too much"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "failed to start"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "closed by the user"
        ApplicationExitInfo.REASON_USER_STOPPED -> "force stopped"
        ApplicationExitInfo.REASON_SIGNALED -> "ended by Android"
        ApplicationExitInfo.REASON_EXIT_SELF -> "exited"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "a permission changed"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "a dependency stopped"
        ApplicationExitInfo.REASON_OTHER -> "other"
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "the app was turned off or on"
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "updated"
        ApplicationExitInfo.REASON_FREEZER -> "frozen in the background by Android"
        else -> "reason $reason"
    }
}
