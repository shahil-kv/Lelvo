package app.lelvo.android.background

import android.content.Context
import android.content.pm.ServiceInfo
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import app.lelvo.android.LelvoApp
import app.lelvo.core.backup.RunRecord
import app.lelvo.core.backup.RunSource
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
        var summary: BackupEngine.Summary? = null
        var cancelled: CancellationException? = null
        var ran = false
        var result = Result.success()
        try {
            if (app.demo.active.value) return Result.success()
            if (!ready()) {
                AppLog.info("Background $kind: Telegram or the library isn't ready; trying later")
                result = if (kind == BackupScheduler.USER) Result.success() else Result.retry()
                return result
            }
            ran = true
            when (kind) {
                BackupScheduler.USER -> summary = userRun()
                BackupScheduler.NEW_PHOTOS -> newPhotos()
                BackupScheduler.AUTO_RUN -> {
                    summary = app.backup.run(userStarted = false, includeNew = false)
                    AppLog.info("Automatic backup: ${summary.text}")
                }
                BackupScheduler.OVERNIGHT -> {
                    summary = app.backup.run(userStarted = false, includeNew = false)
                    AppLog.info("Overnight backup: ${summary.text}")
                    // Then, still on the charger, read new photos for search.
                    if (!isStopped) runCatching { app.search.index() }.onFailure { if (it is CancellationException) throw it }
                }
                BackupScheduler.REFRESH -> {
                    runCatching { app.scanner.catchUp(); app.linker.relink() }
                        .onFailure { if (it is CancellationException) throw it; AppLog.warn("Background index refresh failed", it) }
                }
            }
        } catch (e: CancellationException) {
            cancelled = e
            // Stopped by Android (its time limit, a constraint lost) or paused: the queue keeps what's left.
            AppLog.info(String.format("Background %s stopped after %.0f s%s", kind, (System.currentTimeMillis() - started) / 1000.0,
                if (isStopped) " (WorkManager stop reason $stopReason)" else ""))
        } finally {
            if (ran) record(started, summary, cancelled != null)
        }
        cancelled?.let { if (isStopped) throw it }
        return result
    }

    /** One line in the log and one record, so a phone can be checked without reading a whole log. */
    private fun record(started: Long, summary: BackupEngine.Summary?, cancelled: Boolean) {
        val seconds = (System.currentTimeMillis() - started) / 1000.0
        val stop = when {
            isStopped -> "stopped by Android (reason $stopReason)"
            summary?.stoppedByTime == true -> "out of time"
            summary?.blockedByRule == true && summary.error?.startsWith("Paused") == true -> "paused"
            summary?.error != null -> summary.error
            cancelled && summary == null -> "paused"
            else -> "finished"
        }
        val record = RunRecord(
            source = sourceOf(kind),
            startedAt = started,
            seconds = seconds,
            uploaded = summary?.uploaded ?: 0,
            remaining = summary?.remaining ?: 0,
            stop = stop,
        )
        app.prefs.record(record)
        AppLog.info(String.format("Run (%s): %.0f s, uploaded %d, %,d waiting, %s",
            record.source, record.seconds, record.uploaded, record.remaining, record.stop ?: "finished"))
    }

    private fun sourceOf(kind: String): RunSource = when (kind) {
        BackupScheduler.USER -> RunSource.User
        BackupScheduler.NEW_PHOTOS -> RunSource.NewPhotos
        BackupScheduler.AUTO_RUN -> RunSource.AutoRun
        BackupScheduler.OVERNIGHT -> RunSource.Overnight
        else -> RunSource.Refresh
    }

    /**
     * The content trigger is only a signal. Arm the next one first (this one already fired), then queue photos
     * even when the URI list is empty. The upload is a separate job, so Wi-Fi only and charging only never
     * hold the trigger.
     */
    private suspend fun newPhotos() {
        BackupScheduler.armNewPhotos(applicationContext, app.prefs, ExistingWorkPolicy.APPEND_OR_REPLACE)
        if (!app.prefs.autoBackup || app.prefs.backupPaused) return
        val queued = app.backup.enqueueNew()
        val waiting = app.backup.readyCount()
        AppLog.info("Looked for new photos: $queued queued, $waiting waiting")
        if (waiting > 0) BackupScheduler.startAutoRun(applicationContext, app.prefs, delayMs = 0)
    }

    /** Signed in, Telegram connected (up to 25 s after a cold start, like iOS `waitUntilReady`), and a library unlocked. */
    private suspend fun ready(): Boolean {
        val lib = app.library
        if (!lib.isConfigured || !lib.isUnlocked || !lib.setupFinished) return false
        return withTimeoutOrNull(25_000) { app.telegram.auth.first { it == AuthStep.Ready } } != null
    }

    private suspend fun userRun(): BackupEngine.Summary = coroutineScope {
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
        summary
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
