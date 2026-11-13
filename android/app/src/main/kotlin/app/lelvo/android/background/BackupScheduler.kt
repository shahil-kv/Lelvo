package app.lelvo.android.background

import android.content.Context
import android.provider.MediaStore
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import app.lelvo.core.support.AppLog
import app.lelvo.data.Prefs
import java.util.concurrent.TimeUnit

/**
 * Android's version of iOS `BackgroundTasks` and `ContinuedBackup`, on WorkManager:
 * - **User runs** (Back up now, Back up on chosen photos, Retry, the shortcut and the tile) run as a worker with a
 *   foreground notification, so they keep going when Lelvo leaves the screen (iOS continued-processing task).
 * - **New photos**: with automatic backup on, a MediaStore content trigger starts a run soon after photos are added.
 * - **Overnight**: every few hours while charging, the queue is processed and new photos are read for search (iOS
 *   BGProcessingTask, which also requires power).
 * - **Refresh**: every few hours the index catches up with what other devices did (iOS BGAppRefreshTask).
 *
 * Wi-Fi only and Only while charging become WorkManager constraints for the automatic runs; a user run ignores them
 * here and lets the engine say why it waits, as iOS does.
 */
object BackupScheduler {
    const val USER = "backup.user"
    const val NEW_PHOTOS = "backup.newPhotos"
    const val OVERNIGHT = "backup.overnight"
    const val REFRESH = "index.refresh"

    /** Starts a user run, or queues it right after the one running (chosen photos added meanwhile then go too). */
    fun startNow(context: Context, includeNew: Boolean) {
        val request = OneTimeWorkRequestBuilder<BackupWorker>()
            .setInputData(Data.Builder().putString(BackupWorker.KIND, USER).putBoolean(BackupWorker.INCLUDE_NEW, includeNew).build())
            // Expedited where the quota allows, so it starts at once even in Doze; a normal job otherwise.
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(USER, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }

    /**
     * Brings the automatic work in line with the settings. Called at launch, when a library is ready and when a backup
     * setting changes. [rulesChanged]: Wi-Fi only or charging changed, so the waiting requests take the new constraints.
     */
    fun schedule(context: Context, prefs: Prefs, rulesChanged: Boolean = false) {
        val wm = WorkManager.getInstance(context)
        val network = if (prefs.wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED
        val periodicPolicy = if (rulesChanged) ExistingPeriodicWorkPolicy.UPDATE else ExistingPeriodicWorkPolicy.KEEP

        val overnight = PeriodicWorkRequestBuilder<BackupWorker>(4, TimeUnit.HOURS, 1, TimeUnit.HOURS)
            .setInputData(Data.Builder().putString(BackupWorker.KIND, OVERNIGHT).build())
            .setConstraints(Constraints.Builder().setRequiredNetworkType(network).setRequiresCharging(true).build())
            .setInitialDelay(1, TimeUnit.HOURS)
            .build()
        wm.enqueueUniquePeriodicWork(OVERNIGHT, periodicPolicy, overnight)

        val refresh = PeriodicWorkRequestBuilder<BackupWorker>(4, TimeUnit.HOURS, 1, TimeUnit.HOURS)
            .setInputData(Data.Builder().putString(BackupWorker.KIND, REFRESH).build())
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).setRequiresBatteryNotLow(true).build())
            .setInitialDelay(4, TimeUnit.HOURS)
            .build()
        wm.enqueueUniquePeriodicWork(REFRESH, ExistingPeriodicWorkPolicy.KEEP, refresh)

        if (prefs.autoBackup) armNewPhotos(context, prefs, if (rulesChanged) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP)
        else wm.cancelUniqueWork(NEW_PHOTOS)
    }

    /**
     * Waits for MediaStore to report new photos or videos. A content trigger fires once, so the worker arms the next one
     * when it's done ([ExistingWorkPolicy.APPEND_OR_REPLACE] queues it behind itself instead of cancelling it).
     */
    fun armNewPhotos(context: Context, prefs: Prefs, policy: ExistingWorkPolicy) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(if (prefs.wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
            .setRequiresCharging(prefs.chargingOnly)
            .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
            .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
            // A burst (a few photos, a screen recording being written) becomes one run instead of one each.
            .setTriggerContentUpdateDelay(30, TimeUnit.SECONDS)
            .setTriggerContentMaxDelay(3, TimeUnit.MINUTES)
            .build()
        val request = OneTimeWorkRequestBuilder<BackupWorker>()
            .setInputData(Data.Builder().putString(BackupWorker.KIND, NEW_PHOTOS).build())
            .setConstraints(constraints)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(NEW_PHOTOS, policy, request)
    }

    /** Sign out: nothing runs for the old account. */
    fun cancelAll(context: Context) {
        val wm = WorkManager.getInstance(context)
        listOf(USER, NEW_PHOTOS, OVERNIGHT, REFRESH).forEach(wm::cancelUniqueWork)
        AppLog.info("Background backups cancelled")
    }

    /** Pause from the notification or the tile: the run stops and the queued user runs go too. */
    fun cancelUserRuns(context: Context) = WorkManager.getInstance(context).cancelUniqueWork(USER)
}
