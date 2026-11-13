package app.lelvo.android.background

import android.content.Context
import android.content.pm.ServiceInfo
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import app.lelvo.android.LelvoApp
import app.lelvo.core.support.AppLog
import app.lelvo.data.backup.BackupEngine
import app.lelvo.telegram.AuthStep
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** One background run; [KIND] says which (see [BackupScheduler]). The queue lives in the index, so a stopped run loses nothing. */
class BackupWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    private val app = context.applicationContext as LelvoApp
    private val kind = params.inputData.getString(KIND) ?: BackupScheduler.REFRESH

    override suspend fun doWork(): Result {
        val started = System.currentTimeMillis()
        try {
            if (app.demo.active.value) return Result.success()
            if (!ready()) {
                AppLog.info("Background $kind: Telegram or the library isn't ready; trying later")
                return if (kind == BackupScheduler.USER) Result.success() else Result.retry()
            }
            when (kind) {
                BackupScheduler.USER -> userRun()
                BackupScheduler.NEW_PHOTOS -> {
                    val s = app.backup.run(userStarted = false, includeNew = false)
                    AppLog.info("New photos backup: ${s.text}")
                }
                BackupScheduler.OVERNIGHT -> {
                    val s = app.backup.run(userStarted = false, includeNew = false)
                    AppLog.info("Overnight backup: ${s.text}")
                    // Then, still on the charger, read new photos for search.
                    if (!isStopped) runCatching { app.search.index() }.onFailure { if (it is CancellationException) throw it }
                }
                BackupScheduler.REFRESH -> {
                    runCatching { app.scanner.catchUp(); app.linker.relink() }
                        .onFailure { if (it is CancellationException) throw it; AppLog.warn("Background index refresh failed", it) }
                }
            }
        } catch (e: CancellationException) {
            // Stopped by Android (its time limit, a constraint lost) or paused: the queue keeps what's left.
            AppLog.info(String.format("Background %s stopped after %.0f s%s", kind, (System.currentTimeMillis() - started) / 1000.0,
                if (isStopped) " (WorkManager stop reason $stopReason)" else ""))
            if (isStopped) throw e
        } finally {
            // A content trigger fires once: wait for the next photos (queued behind this run, never cancelling it).
            if (kind == BackupScheduler.NEW_PHOTOS && app.prefs.autoBackup) {
                BackupScheduler.armNewPhotos(applicationContext, app.prefs, ExistingWorkPolicy.APPEND_OR_REPLACE)
            }
        }
        return Result.success()
    }

    /** Signed in, Telegram connected (up to 25 s after a cold start, like iOS `waitUntilReady`), and a library unlocked. */
    private suspend fun ready(): Boolean {
        val lib = app.library
        if (!lib.isConfigured || !lib.isUnlocked || !lib.setupFinished) return false
        return withTimeoutOrNull(25_000) { app.telegram.auth.first { it == AuthStep.Ready } } != null
    }

    private suspend fun userRun() = coroutineScope {
        val includeNew = inputData.getBoolean(INCLUDE_NEW, false)
        val notes = BackupNotifications(applicationContext)
        // Long runs keep going with Lelvo in the background. Android refuses a foreground service started while the
        // app isn't in front (the tile, a shortcut on some versions); then the run is an ordinary job of up to 10
        // minutes and the next run continues.
        val foreground = try {
            setForeground(foregroundInfo(notes.progress(app.backup.activity.value)))
            true
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            AppLog.warn("Backup runs without its notification (${e.javaClass.simpleName})")
            false
        }
        val ticker = if (foreground) launch {
            // Progress in the notification about once a second, with the bytes of the files in flight.
            var last = ""
            while (true) {
                val n = notes.progress(app.backup.activity.value)
                val key = notes.lastKey
                if (key != last) { notes.show(BackupNotifications.PROGRESS_ID, n); last = key }
                delay(1000)
            }
        } else null
        // An automatic run is already uploading: this one follows it (chosen photos added meanwhile then go too).
        app.backup.activity.first { !it.isRunning }
        val summary: BackupEngine.Summary
        try {
            summary = app.backup.run(userStarted = true, includeNew = includeNew)
        } finally {
            ticker?.cancel()
        }
        // Lelvo on screen shows the summary itself; otherwise say how it went, as iOS's system task does.
        if (!app.isOnScreen && summary.error != BackupEngine.StopReason.AlreadyRunning.text) notes.finished(summary)
    }

    override suspend fun getForegroundInfo(): ForegroundInfo =
        foregroundInfo(BackupNotifications(applicationContext).progress(app.backup.activity.value))

    private fun foregroundInfo(n: android.app.Notification) =
        ForegroundInfo(BackupNotifications.PROGRESS_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)

    companion object {
        const val KIND = "kind"
        const val INCLUDE_NEW = "includeNew"
    }
}
