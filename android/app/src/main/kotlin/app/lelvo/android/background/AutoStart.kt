package app.lelvo.android.background

import androidx.work.WorkInfo
import androidx.work.WorkManager
import app.lelvo.android.LelvoApp
import app.lelvo.core.support.AppLog
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Opening Lelvo backs up what is waiting, the way iOS does. It does not cancel an automatic run already
 * going: this process has one engine, and the user run waits for it, then continues with no time limit.
 */
object AutoStart {
    private const val GAP_MS = 5 * 60_000L
    @Volatile private var lastAt = 0L
    private val checking = AtomicBoolean(false)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun onForeground(app: LelvoApp) {
        if (!app.prefs.autoBackup || app.prefs.backupPaused || app.demo.active.value) return
        // Opening three times in a moment must not start three scans. The scan itself runs off the main thread.
        if (!checking.compareAndSet(false, true)) return
        scope.launch {
            try {
                val now = System.currentTimeMillis()
                if (now - lastAt < GAP_MS || workActive(app, BackupScheduler.USER)) return@launch
                if (app.backup.isRunning) {
                    AppLog.info("Auto-start on open: backup already running")
                    lastAt = now
                    BackupScheduler.startNow(app, includeNew = false, fromApp = true)
                    return@launch
                }
                if (app.backup.blocker() != null) return@launch
                app.backup.enqueueNew()
                val waiting = app.backup.readyCount()
                if (waiting == 0) {
                    // Nothing new does not start the 5 minutes, so the next photo is picked up on the next open.
                    AppLog.info("Auto-start on open: nothing new")
                    return@launch
                }
                AppLog.info("Auto-start on open: $waiting waiting")
                lastAt = System.currentTimeMillis()
                BackupScheduler.startNow(app, includeNew = false, fromApp = true)
            } catch (e: Exception) {
                // This scope has no handler: an index or WorkManager error here must not close Lelvo as it opens.
                if (e is kotlinx.coroutines.CancellationException) throw e
                AppLog.warn("Auto-start on open failed (${e.javaClass.simpleName})")
            } finally {
                checking.set(false)
            }
        }
    }

    private fun workActive(app: LelvoApp, name: String): Boolean =
        WorkManager.getInstance(app).getWorkInfosForUniqueWork(name).get()
            .any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }
}
