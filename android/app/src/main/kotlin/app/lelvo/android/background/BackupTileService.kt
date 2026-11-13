package app.lelvo.android.background

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import app.lelvo.android.LelvoApp
import app.lelvo.core.index.ItemStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The Quick Settings tile: Android's version of the iPhone's Shortcuts "Back Up New Photos" and "Backup Status". It shows
 * how the backup stands; a tap starts Back up now, or pauses the backup that's running.
 */
class BackupTileService : TileService() {
    private var scope: CoroutineScope? = null
    private val app get() = applicationContext as LelvoApp

    override fun onStartListening() {
        super.onStartListening()
        scope?.cancel()
        // Assigned before collecting: Main.immediate runs the first refresh at once, and it needs the scope.
        val s = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        scope = s
        s.launch { app.backup.activity.collect { refresh() } }
    }

    override fun onStopListening() {
        scope?.cancel(); scope = null
        super.onStopListening()
    }

    private var refreshJob: Job? = null

    private fun refresh() {
        refreshJob?.cancel()
        refreshJob = scope?.launch {
            val tile = qsTile ?: return@launch
            val a = app.backup.activity.value
            val ready = app.library.isConfigured && app.library.isUnlocked && app.library.setupFinished && !app.demo.active.value
            tile.label = "Lelvo backup"
            val subtitle = when {
                !ready -> "Open Lelvo to set up"
                a.isRunning -> if (a.total > 0) "${a.done} of ${a.total}" else "Starting…"
                app.prefs.backupPaused -> "Paused"
                else -> status()
            }
            tile.state = when {
                !ready -> Tile.STATE_UNAVAILABLE
                a.isRunning -> Tile.STATE_ACTIVE
                else -> Tile.STATE_INACTIVE
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) tile.subtitle = subtitle
            tile.contentDescription = "Lelvo backup, $subtitle"
            tile.updateTile()
        }
    }

    /** Short form of iOS's Backup Status: what's waiting or failed, else that everything is backed up. */
    private suspend fun status(): String {
        val c = runCatching { app.backup.counts() }.getOrNull() ?: return "Back up now"
        val pending = c.pending(app.prefs.autoBackup)
        return when {
            c.failed > 0 && pending > 0 -> "$pending waiting, ${c.failed} failed"
            c.failed > 0 -> "${c.failed} failed"
            pending > 0 -> "$pending waiting"
            else -> "${"%,d".format(runCatching { app.store.items(ItemStatus.BackedUp).size }.getOrDefault(0))} backed up"
        }
    }

    override fun onClick() {
        super.onClick()
        val ready = app.library.isConfigured && app.library.isUnlocked && app.library.setupFinished && !app.demo.active.value
        if (!ready) return
        if (app.backup.activity.value.isRunning) app.pauseBackup() else app.startBackup(includeNew = true)
        refresh()
    }

    companion object {
        /** Asks Android to redraw the tile (it only listens while Quick Settings is open). */
        fun update(context: Context) = runCatching {
            requestListeningState(context, ComponentName(context, BackupTileService::class.java))
        }
    }
}
