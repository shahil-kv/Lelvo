package app.lelvo.android.collections

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.selected
import app.lelvo.android.shell.Messages
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.core.index.CloudTrash
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.LibraryItem
import app.lelvo.data.DemoMode
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Items deleted from your Telegram library, kept 30 days (iOS `RecentlyDeletedView`), with the days left on each
 * tile like Google Photos' Trash. Long-press selects; the bottom bar recovers or deletes the selection, or everything
 * when nothing is selected. Both send notes, so every device follows.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun RecentlyDeletedScreen(app: LelvoApp, onBack: () -> Unit) {
    val items by produceState<List<LibraryItem>?>(null) {
        app.store.items().map(CloudTrash::items).flowOn(Dispatchers.Default).collect { value = it }
    }
    val selection = remember { mutableStateListOf<String>() }
    var confirmDelete by remember { mutableStateOf<List<LibraryItem>?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    androidx.activity.compose.BackHandler { if (selection.isNotEmpty()) selection.clear() else onBack() }
    // Emptied or recovered from another device: drop what's gone from the selection.
    LaunchedEffect(items) { items?.let { list -> val ids = list.map { it.id }.toHashSet(); selection.retainAll { it in ids } } }

    fun run(work: suspend () -> Unit, failTitle: String) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                work()
                haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                selection.clear()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                AppLog.warn("Recently Deleted: $failTitle", e)
                Messages.show(Messages.Style.Failure, failTitle, e.message ?: "Check your connection and try again.", seconds = 5.0)
            } finally {
                busy = false
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    if (selection.isEmpty()) IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") }
                    else IconButton(onClick = { selection.clear() }) { Icon(painterResource(R.drawable.ic_close), "Clear selection") }
                },
                title = { Text(if (selection.isEmpty()) "Recently Deleted" else "${selection.size} selected") },
            )
        },
        bottomBar = {
            val list = items.orEmpty()
            if (list.isNotEmpty()) {
                val targets = if (selection.isEmpty()) list else list.filter { it.id in selection }
                val all = selection.isEmpty()
                Surface(tonalElevation = 3.dp, shadowElevation = 6.dp) {
                    Row(
                        Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 12.dp, vertical = 6.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        TextButton(onClick = { confirmDelete = targets }, enabled = !busy) {
                            Text(if (all) "Delete all" else "Delete", color = Lelvo.colors.red)
                        }
                        TextButton(onClick = {
                            run({
                                val n = withContext(Dispatchers.IO) { app.sync.recover(targets) }
                                Messages.show(Messages.Style.Success, if (n == 1) "Recovered 1 item" else "Recovered $n items")
                            }, "Couldn't recover")
                        }, enabled = !busy) { Text(if (all) "Recover all" else "Recover") }
                    }
                }
            }
        },
    ) { padding ->
        val list = items ?: return@Scaffold
        if (list.isEmpty()) {
            Column(
                Modifier.fillMaxSize().padding(padding).padding(32.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(painterResource(R.drawable.ic_delete), null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("No recently deleted items", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Items you delete from your backup stay here for 30 days before they're removed from your Telegram library.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            return@Scaffold
        }
        val now = System.currentTimeMillis()
        val dateFormat = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.LONG, FormatStyle.SHORT)
        Box(Modifier.fillMaxSize()) {
            LazyVerticalGrid(
                GridCells.Adaptive(110.dp), contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 24.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp), verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "note") {
                    Text(
                        "Items stay here for 30 days, then they're removed from your Telegram library. Photos still on this phone aren't affected.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                    )
                }
                items(list, key = { it.id }) { item ->
                    val days = CloudTrash.daysLeft(item, now)
                    val left = if (days == 1) "1 day" else "$days days"
                    val kind = if (item.kind == ItemKind.Video) "Video" else "Photo"
                    val date = item.createdAt?.let { dateFormat.format(Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault())) } ?: "Unknown date"
                    val selected = item.id in selection
                    fun toggle() { if (selected) selection.remove(item.id) else selection.add(item.id) }
                    Box(
                        Modifier.aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceVariant)
                            .combinedClickable(
                                onClick = { if (selection.isNotEmpty()) toggle() },
                                onLongClick = { haptics.performHapticFeedback(HapticFeedbackType.LongPress); toggle() },
                            )
                            .clearAndSetSemantics {
                                contentDescription = "$kind, $date, $left left"
                                this.selected = selected
                            },
                    ) {
                        AsyncImage(
                            DemoMode.assetUri(item) ?: CloudThumbnail(item), null, contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize().padding(if (selected) 10.dp else 0.dp),
                        )
                        Text(
                            left, color = Color.White,
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold, shadow = Shadow(Color.Black.copy(alpha = 0.6f), blurRadius = 4f)),
                            modifier = Modifier.align(Alignment.BottomStart).padding(if (selected) 13.dp else 5.dp),
                        )
                        if (selection.isNotEmpty()) Icon(
                            painterResource(if (selected) R.drawable.ic_check_circle else R.drawable.ic_circle_outline), null,
                            tint = if (selected) MaterialTheme.colorScheme.primary else Color.White,
                            modifier = Modifier.align(Alignment.TopStart).padding(4.dp).size(22.dp)
                                .background(if (selected) MaterialTheme.colorScheme.surface else Color.Transparent, CircleShape),
                        )
                    }
                }
            }
            if (busy) CircularProgressIndicator(Modifier.align(Alignment.Center))
        }
    }

    confirmDelete?.let { targets ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text(if (targets.size == 1) "Delete this item from your Telegram library?" else "Delete ${targets.size} items from your Telegram library?") },
            text = { Text("This can't be undone. Photos still on this phone aren't affected.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = null
                    run({
                        withContext(Dispatchers.IO) { app.sync.deletePermanently(targets) }
                        Messages.show(Messages.Style.Success, "Deleted from your Telegram library")
                    }, "Couldn't delete")
                }) { Text("Delete from Telegram", color = Lelvo.colors.red) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Cancel") } },
        )
    }
}
