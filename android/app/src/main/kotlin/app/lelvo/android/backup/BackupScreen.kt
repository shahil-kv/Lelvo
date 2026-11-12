package app.lelvo.android.backup

import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.shell.LelvoTopBar
import app.lelvo.android.shell.Messages
import app.lelvo.android.timeline.galleryEntries
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.backup.BackupCounts
import app.lelvo.core.index.BackupBadge
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.data.LibraryException
import app.lelvo.data.backup.BackupActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat

/** What the Backup tab counts (iOS `BackupStats`). */
private data class Stats(
    val onPhone: Int = 0, val backedUp: Int = 0, val cloudOnly: Int = 0, val counts: BackupCounts = BackupCounts(),
    val failedItems: List<LibraryItem> = emptyList(), val removed: Int = 0,
)

/**
 * The Backup tab (iOS `BackupDashboardView`), laid out like Google Photos' backup page: one status line with what's
 * left, one main button, a progress row per upload, then the library's counts. Failed items open their own list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackupScreen(app: LelvoApp, onSettings: () -> Unit, modifier: Modifier = Modifier) {
    val engine = app.backup
    val activity by engine.activity.collectAsState()
    val isDemo by app.demo.active.collectAsState()
    val scope = rememberCoroutineScope()
    var showFailed by rememberSaveable { mutableStateOf(false) }
    val stats by produceState(Stats(), isDemo) {
        // Recounted when the index or the phone's photos change, and when a run moves on.
        galleryEntries(app.store, app.photos, isDemo).collectLatest { entries ->
            value = withContext(Dispatchers.IO) {
                val counts = engine.counts()
                val trashed = app.store.items(ItemStatus.Trashed)
                val phoneIds = entries.mapNotNull { it.asset?.localId }.toHashSet()
                Stats(
                    onPhone = entries.count { it.asset != null },
                    backedUp = entries.count { it.badge == BackupBadge.BackedUp },
                    cloudOnly = entries.count { it.badge == BackupBadge.CloudOnly },
                    counts = counts,
                    failedItems = app.store.items(ItemStatus.Failed).sortedByDescending { it.createdAt ?: 0 },
                    removed = BackupCounts.removedFromBackup(trashed, app.store.offBackupLocalIds(), app.store.knownLocalIds(), phoneIds).size,
                )
            }
        }
    }
    // Until Phase N, a debug build writes only to the "Android test" library: say so before anyone taps.
    val writeBlock by produceState<String?>(null, isDemo) {
        value = withContext(Dispatchers.IO) {
            val chat = app.library.chatId ?: return@withContext null
            try { app.library.requireWritable(chat); null } catch (e: LibraryException) { e.message }
        }
    }
    LaunchedEffect(activity.lastSummary) {
        val s = activity.lastSummary ?: return@LaunchedEffect
        when {
            s.error != null -> Messages.show(Messages.Style.Info, s.text, seconds = 5.0)
            s.uploaded == 0 && s.alreadyBackedUp == 0 && s.failed == 0 && s.remaining == 0 -> Messages.show(Messages.Style.Success, "Everything is backed up")
            else -> Messages.show(if (s.failed > 0) Messages.Style.Failure else Messages.Style.Success, s.text)
        }
    }

    if (showFailed) {
        FailedScreen(stats.failedItems, onBack = { showFailed = false }, onRetry = {
            scope.launch { if (engine.retryFailed() > 0) engine.start(includeNew = false) }
        }, modifier = modifier)
        return
    }

    Scaffold(modifier, topBar = { LelvoTopBar("Backup", app.demo, onSettings) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            item("header") { StatusHeader(activity, stats, app.prefs.lastBackupAt) }
            item("buttons") {
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    writeBlock?.let {
                        Text(it, style = MaterialTheme.typography.bodyMedium, color = Lelvo.colors.orange, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                    }
                    if (activity.isRunning) {
                        OutlinedButton(onClick = { Messages.show(Messages.Style.Info, "Pausing the backup"); engine.pause() }, modifier = Modifier.fillMaxWidth()) {
                            Icon(painterResource(R.drawable.ic_pause), contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp)); Text("Pause backup")
                        }
                    } else {
                        Button(onClick = { engine.start(includeNew = true) }, enabled = writeBlock == null && !isDemo, modifier = Modifier.fillMaxWidth()) {
                            Icon(painterResource(R.drawable.ic_cloud_upload), contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp)); Text(if (app.prefs.backupPaused) "Resume backup" else "Back up now")
                        }
                        if (app.prefs.backupPaused) {
                            Text("Paused. Automatic backups won't run until you resume.", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                        }
                        if (stats.counts.retryable > 0) {
                            OutlinedButton(onClick = {
                                Messages.show(Messages.Style.Info, "Retrying ${stats.counts.retryable} failed")
                                scope.launch { engine.retryFailed(); engine.start(includeNew = false) }
                            }, enabled = writeBlock == null, modifier = Modifier.fillMaxWidth()) {
                                Icon(painterResource(R.drawable.ic_sync), contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp)); Text("Retry ${stats.counts.retryable} failed")
                            }
                        }
                    }
                }
            }
            if (activity.isRunning) item("progress") { RunProgress(activity) }
            val rules = listOfNotNull(if (app.prefs.wifiOnly) "Wi-Fi only" else null, if (app.prefs.chargingOnly) "charging only" else null)
            if (rules.isNotEmpty()) item("rules") {
                Text(rules.joinToString(", ").replaceFirstChar { it.uppercase() } + ". Change in Settings.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
            }
            item("library") {
                HorizontalDivider(Modifier.padding(top = 8.dp))
                Text("Library", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp).semantics { heading() })
                StatRow("On this phone", stats.onPhone, R.drawable.ic_phone, MaterialTheme.colorScheme.onSurfaceVariant)
                StatRow("Backed up (verified)", stats.backedUp, R.drawable.ic_cloud_done, Lelvo.colors.green)
                StatRow("Only in the cloud", stats.cloudOnly, R.drawable.ic_cloud, MaterialTheme.colorScheme.onSurfaceVariant)
                StatRow("Waiting to upload", stats.counts.pending(app.prefs.autoBackup), R.drawable.ic_schedule, MaterialTheme.colorScheme.onSurfaceVariant)
                if (stats.counts.failed > 0) {
                    StatRow("Failed", stats.counts.failed, R.drawable.ic_error, Lelvo.colors.red, onClick = { showFailed = true })
                }
                if (stats.removed > 0) StatRow("Removed from backup", stats.removed, R.drawable.ic_cloud_off, MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun StatusHeader(activity: BackupActivity, stats: Stats, lastBackupAt: Long?) {
    val c = stats.counts
    val pending = c.pending(autoBackup = false).coerceAtLeast(c.activeQueue)
    val left = if (activity.isRunning && activity.total > 0) activity.remaining else pending
    val (icon, tint, title) = when {
        activity.isRunning || pending > 0 -> Triple(R.drawable.ic_cloud_upload, Lelvo.colors.accent, "$left item${if (left == 1) "" else "s"} left to back up")
        c.notQueued > 0 -> Triple(R.drawable.ic_cloud_off, MaterialTheme.colorScheme.onSurfaceVariant, "${c.notQueued} item${if (c.notQueued == 1) "" else "s"} not in the cloud")
        c.failed > 0 -> Triple(R.drawable.ic_error, Lelvo.colors.orange, "Backup complete, ${c.failed} item${if (c.failed == 1) "" else "s"} couldn't be backed up")
        else -> Triple(R.drawable.ic_cloud_done, Lelvo.colors.green, "Backup complete")
    }
    val subtitle = when {
        activity.isRunning || pending > 0 -> "To your Telegram library"
        c.notQueued > 0 -> "Back up now uploads them all, or choose photos in Photos and tap Back up."
        else -> "Everything${if (stats.removed > 0) " else" else ""} on this phone is backed up"
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(painterResource(icon), contentDescription = null, tint = tint, modifier = Modifier.size(56.dp))
        AnimatedContent(title, label = "backup title") { Text(it, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center) }
        Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        activity.notice?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Lelvo.colors.orange, textAlign = TextAlign.Center) }
        if (activity.isRunning) activity.message?.takeIf { it.startsWith("Waiting") || it.startsWith("No internet") }?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = Lelvo.colors.orange, textAlign = TextAlign.Center)
        }
        lastBackupAt?.let {
            Text("Last upload ${DateUtils.getRelativeTimeSpanString(it, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)}",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun RunProgress(a: BackupActivity) {
    val context = LocalContext.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (a.total > 0) {
            LinearProgressIndicator(progress = { a.done.toFloat() / a.total }, modifier = Modifier.fillMaxWidth())
            Text("${a.done} of ${a.total} done · ${a.remaining} left", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            a.message?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        if (a.failed > 0) Text("${a.failed} failed in this run (see Failed below)", style = MaterialTheme.typography.bodySmall, color = Lelvo.colors.red)
        for ((key, lane) in a.lanes.toSortedMap()) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(lane.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
                if (lane.total > 0) {
                    LinearProgressIndicator(progress = { (lane.sent.toFloat() / lane.total).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                    val left = a.secondsLeft[key]?.let { s -> " · about ${if (s < 60) "$s s" else "${(s + 59) / 60} min"} left" } ?: ""
                    Text("${Formatter.formatShortFileSize(context, lane.sent)} of ${Formatter.formatShortFileSize(context, lane.total)}$left",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    Text("Preparing…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun StatRow(title: String, value: Int, icon: Int, tint: Color, onClick: (() -> Unit)? = null) {
    ListItem(
        headlineContent = { Text(title) },
        leadingContent = { Icon(painterResource(icon), contentDescription = null, tint = tint) },
        trailingContent = { Text("%,d".format(value), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant) },
        modifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier,
    )
}

/** Failed uploads with their reason (iOS `FailedUploadsView`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FailedScreen(items: List<LibraryItem>, onBack: () -> Unit, onRetry: () -> Unit, modifier: Modifier) {
    BackHandler(onBack = onBack)
    val format = remember { DateFormat.getDateInstance(DateFormat.MEDIUM) }
    Scaffold(modifier, topBar = {
        TopAppBar(
            title = { Text("Failed uploads") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") } },
        )
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            if (items.any { !it.isStrandedInCloud && it.localId != null }) item("retry") {
                OutlinedButton(onClick = onRetry, modifier = Modifier.fillMaxWidth().padding(16.dp)) { Text("Retry all failed") }
            }
            if (items.isEmpty()) item("empty") {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Nothing failed", style = MaterialTheme.typography.titleMedium)
                    Text("Every attempted upload went through.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            items(items, key = { it.id }) { item ->
                ListItem(
                    headlineContent = { Text(item.filename, maxLines = 1) },
                    supportingContent = {
                        Column {
                            Text(if (item.isStrandedInCloud) "Incomplete in your Telegram library" else item.lastError ?: "Unknown error", color = Lelvo.colors.red)
                            Text("${item.createdAt?.let { format.format(java.util.Date(it)) } ?: "No date"} · ${item.attempts} attempt(s)",
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    },
                )
            }
        }
    }
}
