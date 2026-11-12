package app.lelvo.android.background

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import app.lelvo.android.LelvoApp
import app.lelvo.android.MainActivity
import app.lelvo.android.R
import app.lelvo.data.backup.BackupActivity
import app.lelvo.data.backup.BackupEngine

/** The backup's notification: progress with Pause while a user run works, then how it went (iOS's system task UI). */
class BackupNotifications(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    /** What the last [progress] showed, so the same text isn't posted again every second. */
    var lastKey = ""
        private set

    init {
        // Low importance: no sound, no pop-up, like Google Photos' backup notification.
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Backup", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Progress while Lelvo backs up to your Telegram library"
            setShowBadge(false)
        })
    }

    fun progress(a: BackupActivity): Notification {
        val inFlight = a.lanes.values.sumOf { if (it.total > 0) it.sent.toDouble() / it.total else 0.0 }
        val total = maxOf(a.total, 1) * 100
        val done = minOf(total - 1, a.done * 100 + (inFlight * 100).toInt())
        val text = when {
            a.total > 0 -> "${a.done} of ${a.total} items"
            else -> a.message ?: "Preparing…"
        }
        lastKey = "$text|${done * 100 / total}|${a.notice}"
        return NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_cloud_upload)
            .setContentTitle("Backing up to Telegram")
            .setContentText(text)
            .apply { a.notice?.let { setStyle(NotificationCompat.BigTextStyle().bigText("$text\n$it")) } }
            .setProgress(total, done, a.total == 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp())
            .addAction(R.drawable.ic_pause, "Pause", PendingIntent.getBroadcast(context, 1,
                Intent(context, PauseReceiver::class.java), PendingIntent.FLAG_IMMUTABLE))
            .build()
    }

    fun finished(s: BackupEngine.Summary) {
        val paused = s.error != null
        show(DONE_ID, NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(if (paused) R.drawable.ic_pause else R.drawable.ic_cloud_done)
            .setContentTitle(if (paused) "Backup paused" else "Backup finished")
            .setContentText(s.text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(s.text))
            .setAutoCancel(true)
            .setContentIntent(openApp())
            .build())
    }

    fun show(id: Int, n: Notification) {
        // Android 13+: without the permission the run still works; only the notification is missing.
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        manager.notify(id, n)
    }

    private fun openApp() = PendingIntent.getActivity(context, 0,
        Intent(context, MainActivity::class.java).setAction(MainActivity.ACTION_OPEN_BACKUP).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE)

    companion object {
        const val CHANNEL = "backup"
        const val PROGRESS_ID = 41
        const val DONE_ID = 42
    }
}

/** Pause in the notification: the same as Pause backup on the Backup tab. */
class PauseReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        (context.applicationContext as LelvoApp).pauseBackup()
    }
}
