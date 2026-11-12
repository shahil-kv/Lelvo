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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
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
import app.lelvo.data.media.PhotoAccess
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
    var page by rememberSaveable { mutableStateOf(Page.Main) }
    // The Free up space shortcut opens that page.
    LaunchedEffect(Unit) { app.model.openFreeUpSpace.collect { if (it) { page = Page.FreeUp; app.model.openFreeUpSpace.value = false } } }
    // Android 13+: asked once, the first time a backup is started, so its progress can show while Lelvo is closed.
    val notificationAsk = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) { }
    val askNotifications = {
        if (android.os.Build.VERSION.SDK_INT >= 33 && !app.prefs.askedNotifications) {
            app.prefs.askedNotifications = true
            notificationAsk.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    val demoRun by app.demo.backup.collectAsState()
    val stats by produceState(Stats(), isDemo) {
        // Recounted when the index or the phone's photos change, and when a run moves on.
        galleryEntries(app.store, app.photos, isDemo).collectLatest { entries ->
            value = withContext(Dispatchers.IO) {
                // Demo: the sample items waiting for "Back up now" stand in for this phone's photos.
                val counts = if (isDemo) BackupCounts(notQueued = app.demo.pendingItems().size) else engine.counts()
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

    val back = { page = Page.Main }
    when (page) {
        Page.Failed -> return FailedScreen(app, stats.failedItems, onBack = back, onRetry = {
            scope.launch { if (engine.retryFailed() > 0) app.startBackup(includeNew = false) }
        }, modifier = modifier)
        Page.FreeUp -> return FreeUpSpaceScreen(app, back, modifier)
        Page.SaveAll -> return SaveAllScreen(app, back, modifier)
        Page.Removed -> return RemovedScreen(app, back, modifier)
        Page.Duplicates -> return DuplicatesScreen(app, back, modifier)
        Page.SecondCopy -> return SecondCopyScreen(app, back, modifier)
        Page.Main -> Unit
    }
    // While a backup runs and Lelvo is open, the screen stays on (iOS "Keep iPhone awake").
    val context = androidx.compose.ui.platform.LocalContext.current
    var keepAwake by remember { mutableStateOf(app.prefs.keepAwakeDuringBackup) }
    if (activity.isRunning && keepAwake) androidx.compose.runtime.DisposableEffect(Unit) {
        val window = (context as? android.app.Activity)?.window
        window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
    val access = remember(stats) { app.photos.status() }

    // The App Review demo "uploads" its sample items with real progress and no network.
    val shown = demoRun?.takeIf { isDemo }?.let { d ->
        BackupActivity(isRunning = d.running, done = d.done, total = d.total, uploaded = d.done,
            lanes = d.current.withIndex().associate { (i, n) -> "$i" to BackupActivity.Lane(n, 0, 0) })
    } ?: activity
    Scaffold(modifier, topBar = { LelvoTopBar("Backup", app.demo, onSettings) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            item("header") { StatusHeader(shown, stats, app.prefs.lastBackupAt) }
            item("buttons") {
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    writeBlock?.let {
                        Text(it, style = MaterialTheme.typography.bodyMedium, color = Lelvo.colors.orange, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                    }
                    if (activity.isRunning) {
                        OutlinedButton(onClick = { Messages.show(Messages.Style.Info, "Pausing the backup"); app.pauseBackup() }, modifier = Modifier.fillMaxWidth()) {
                            Icon(painterResource(R.drawable.ic_pause), contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp)); Text("Pause backup")
                        }
                    } else {
                        Button(onClick = { if (isDemo) scope.launch { app.demo.runBackup() } else { askNotifications(); app.startBackup(includeNew = true) } },
                            enabled = isDemo || writeBlock == null, modifier = Modifier.fillMaxWidth()) {
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
                                scope.launch { engine.retryFailed(); app.startBackup(includeNew = false) }
                            }, enabled = writeBlock == null, modifier = Modifier.fillMaxWidth()) {
                                Icon(painterResource(R.drawable.ic_sync), contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp)); Text("Retry ${stats.counts.retryable} failed")
                            }
                        }
                    }
                }
            }
            if (shown.isRunning) item("progress") { RunProgress(shown) }
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
                    StatRow("Failed", stats.counts.failed, R.drawable.ic_error, Lelvo.colors.red, onClick = { page = Page.Failed })
                }
                if (stats.removed > 0) StatRow("Removed from backup", stats.removed, R.drawable.ic_cloud_off, MaterialTheme.colorScheme.onSurfaceVariant,
                    onClick = { page = Page.Removed })
            }
            item("awake") {
                HorizontalDivider(Modifier.padding(top = 8.dp))
                ListItem(
                    headlineContent = { Text("Keep the screen on while backing up") },
                    supportingContent = {
                        Text(if (keepAwake) "While a backup runs and Lelvo is open, your phone won't lock. It locks as usual once the backup is done."
                            else "Your phone may lock and pause a backup; open Lelvo to continue.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    },
                    trailingContent = { androidx.compose.material3.Switch(keepAwake, { keepAwake = it; app.prefs.keepAwakeDuringBackup = it }) },
                )
                if (access == PhotoAccess.Status.Partial) {
                    ListItem(
                        leadingContent = { Icon(painterResource(R.drawable.ic_warning), null, tint = Lelvo.colors.orange) },
                        headlineContent = { Text("Limited photo access: only photos you selected are backed up.") },
                        supportingContent = { Text("Allow full access in Settings", color = MaterialTheme.colorScheme.primary) },
                        modifier = Modifier.clickable {
                            context.startActivity(android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.fromParts("package", context.packageName, null)))
                        },
                    )
                }
            }
            item("tools") {
                HorizontalDivider(Modifier.padding(top = 8.dp))
                Text("Tools", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp).semantics { heading() })
                ToolRow("Free up space", R.drawable.ic_phone) { page = Page.FreeUp }
                ToolRow("Save all to this phone", R.drawable.ic_download) { page = Page.SaveAll }
                ToolRow("Extra copies and duplicates", R.drawable.ic_collections) { page = Page.Duplicates }
                ToolRow("Second copy to a folder", R.drawable.ic_folder) { page = Page.SecondCopy }
                ToolRow("Re-scan the Telegram library", R.drawable.ic_sync) {
                    scope.launch {
                        Messages.progress("Re-scanning…")
                        try {
                            val r = app.model.rescan()
                            Messages.show(Messages.Style.Success, "Library re-scanned", "${"%,d".format(r.items)} items")
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Messages.show(Messages.Style.Failure, "Couldn't re-scan", e.message)
                        }
                    }
                }
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

private enum class Page { Main, Failed, FreeUp, SaveAll, Removed, Duplicates, SecondCopy }

@Composable
private fun ToolRow(title: String, icon: Int, onClick: () -> Unit) {
    ListItem(headlineContent = { Text(title) }, leadingContent = { Icon(painterResource(icon), null) }, modifier = Modifier.clickable(onClick = onClick))
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
private fun FailedScreen(app: LelvoApp, items: List<LibraryItem>, onBack: () -> Unit, onRetry: () -> Unit, modifier: Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val trash = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.StartIntentSenderForResult()) { r ->
        if (r.resultCode == android.app.Activity.RESULT_OK) Messages.show(Messages.Style.Success, "Moved to the phone's trash")
    }
    val stranded = items.filter { it.isStrandedInCloud }
    val scope = rememberCoroutineScope()
    var confirmStranded by remember { mutableStateOf(false) }
    if (confirmStranded) AlertDialog(
        onDismissRequest = { confirmStranded = false },
        title = { Text("Move ${stranded.size} incomplete item${if (stranded.size == 1) "" else "s"} to Recently Deleted?") },
        text = { Text("What's left of them stays there for 30 days, then it's deleted from your Telegram library.") },
        confirmButton = {
            TextButton(onClick = {
                confirmStranded = false
                val targets = stranded
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) { app.sync.deleteFromCloud(targets) }
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Messages.show(Messages.Style.Failure, "Couldn't delete", e.message ?: "Try again.", seconds = 5.0)
                    }
                }
            }) { Text("Move to Recently Deleted", color = Lelvo.colors.red) }
        },
        dismissButton = { TextButton(onClick = { confirmStranded = false }) { Text("Cancel") } },
    )
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
            if (stranded.isNotEmpty()) item("stranded") {
                Note("Part of ${if (stranded.size == 1) "this item is" else "these ${stranded.size} items are"} missing from your Telegram library, and ${if (stranded.size == 1) "it isn't" else "they aren't"} on this phone. Back up from the device that has ${if (stranded.size == 1) "it" else "them"}, or move what's left to Recently Deleted.")
                TextButton(onClick = { confirmStranded = true }, modifier = Modifier.padding(horizontal = 8.dp)) {
                    Text("Move ${stranded.size} to Recently Deleted", color = Lelvo.colors.red)
                }
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
                    trailingContent = item.localId?.takeIf { android.os.Build.VERSION.SDK_INT >= 30 }?.let { id ->
                        {
                            IconButton(onClick = {
                                scope.launch {
                                    val uri = withContext(Dispatchers.IO) { app.backup.phone.file(id)?.uri } ?: return@launch
                                    val pi = android.provider.MediaStore.createTrashRequest(context.contentResolver, listOf(uri), true)
                                    trash.launch(androidx.activity.result.IntentSenderRequest.Builder(pi.intentSender).build())
                                }
                            }) { Icon(painterResource(R.drawable.ic_delete), contentDescription = "Delete from this phone") }
                        }
                    },
                )
            }
        }
    }
}
