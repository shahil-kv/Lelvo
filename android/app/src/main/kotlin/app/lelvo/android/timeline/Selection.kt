package app.lelvo.android.timeline

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.actions.DeleteDialog
import app.lelvo.android.actions.rememberPhoneActions
import app.lelvo.android.actions.shareEntries
import app.lelvo.android.shell.Messages
import app.lelvo.core.index.GalleryEntry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

/**
 * Google Photos' selection on the grid: a long press selects a photo and dragging on selects every photo between
 * (or clears them, when the first one was already selected), scrolling when the finger nears an edge. The iPhone does
 * the same with its Select button and a swipe (iOS #79).
 */
internal fun Modifier.dragToSelect(
    state: LazyGridState,
    order: () -> List<String>,
    selection: () -> Set<String>,
    onChange: (Set<String>) -> Unit,
    onStart: () -> Unit,
    edge: Float,
    onEdge: (Float) -> Unit,
): Modifier = pointerInput(Unit) {
    var anchor = -1
    var adding = true
    var base = emptySet<String>()
    fun indexAt(p: Offset): Int {
        val key = state.layoutInfo.visibleItemsInfo.firstOrNull {
            p.x >= it.offset.x && p.x < it.offset.x + it.size.width && p.y >= it.offset.y && p.y < it.offset.y + it.size.height
        }?.key as? String ?: return -1
        return order().indexOf(key)
    }
    fun select(to: Int) {
        if (anchor < 0 || to < 0) return
        val ids = order()
        val range = ids.subList(minOf(anchor, to), maxOf(anchor, to) + 1).toSet()
        onChange(if (adding) base + range else base - range)
    }
    detectDragGesturesAfterLongPress(
        onDragStart = { p ->
            anchor = indexAt(p)
            if (anchor < 0) return@detectDragGesturesAfterLongPress
            onStart()
            base = selection()
            adding = order()[anchor] !in base
            select(anchor)
        },
        onDragEnd = { anchor = -1; onEdge(0f) },
        onDragCancel = { anchor = -1; onEdge(0f) },
    ) { change, _ ->
        if (anchor < 0) return@detectDragGesturesAfterLongPress
        change.consume()
        val y = change.position.y
        onEdge(
            when {
                y < edge -> -(edge - y) / edge
                y > size.height - edge -> (y - (size.height - edge)) / edge
                else -> 0f
            },
        )
        select(indexAt(change.position))
    }
}

/** Scrolls while a drag-to-select finger rests near the top or bottom edge, faster the closer it is. */
@Composable
internal fun EdgeScroll(state: LazyGridState, speed: Float) {
    val current by rememberUpdatedState(speed)
    LaunchedEffect(state) {
        while (true) {
            if (current != 0f) state.scrollBy(current * 40f)
            delay(16)
        }
    }
}

/** The action row while photos are selected: Share, Favorite and Delete, as in Google Photos. */
@Composable
internal fun SelectionActions(chosen: List<GalleryEntry>, onDone: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var confirmDelete by remember { mutableStateOf(false) }
    var sharing by remember { mutableStateOf(false) }
    val actions = rememberPhoneActions(onFavorited = { onDone() }, onTrashed = onDone)
    val allFavorite = chosen.isNotEmpty() && chosen.all { it.isFavorite }

    if (sharing) LaunchedEffect(chosen) {
        try {
            shareEntries(context, chosen)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Messages.show(Messages.Style.Failure, "Couldn't share", e.message ?: "Check your connection and try again.")
        } finally {
            sharing = false
        }
    }

    Surface(modifier.fillMaxWidth(), tonalElevation = 3.dp, shadowElevation = 6.dp) {
        Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
            Action(R.drawable.ic_send, "Share", enabled = chosen.isNotEmpty() && !sharing) { sharing = true }
            // Phone photos not in the cloud yet: queued as chosen, so they go even with automatic backup off.
            val toBackUp = chosen.filter { it.asset != null && it.badge != app.lelvo.core.index.BackupBadge.BackedUp }
            if (toBackUp.isNotEmpty()) Action(R.drawable.ic_cloud_upload, "Back up", enabled = true) {
                val app = context.applicationContext as app.lelvo.android.LelvoApp
                scope.launch {
                    val n = app.backup.enqueue(toBackUp.mapNotNull { it.asset?.localId })
                    Messages.show(Messages.Style.Info, if (n == 0) "Already backed up" else "Backing up $n item${if (n == 1) "" else "s"}")
                    if (n > 0) app.backup.start(includeNew = false)
                    onDone()
                }
            }
            Action(R.drawable.ic_favorite, if (allFavorite) "Unfavorite" else "Favorite", enabled = chosen.any { it.asset != null }) {
                actions.favorite(chosen, !allFavorite)
            }
            Action(R.drawable.ic_delete, "Delete", enabled = chosen.isNotEmpty()) { confirmDelete = true }
        }
    }

    if (confirmDelete) DeleteDialog(chosen, onDismiss = { confirmDelete = false }, onRemove = { confirmDelete = false; actions.trash(chosen) })
}

@Composable
private fun Action(icon: Int, label: String, enabled: Boolean, onClick: () -> Unit) {
    TextButton(onClick = onClick, enabled = enabled) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(painterResource(icon), null)
            Text(label, style = MaterialTheme.typography.labelMedium)
        }
    }
}

