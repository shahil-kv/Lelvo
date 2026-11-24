package app.lelvo.android.timeline

import app.lelvo.data.ProStore
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.actions.DeleteDialog
import app.lelvo.android.actions.AlbumActions
import app.lelvo.android.actions.AddToAlbumDialog
import app.lelvo.android.LelvoApp
import app.lelvo.android.collections.RemoveFromPhoneAfterLockSheet
import app.lelvo.android.collections.confirmLockIntent
import app.lelvo.android.collections.mediaItemsAfterLock
import app.lelvo.android.collections.removableAfterLock
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.BackupBadge
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
    onStep: () -> Unit = {},
): Modifier {
    // Set once a long press has started selecting. Tiles are plain clickables, which take a press held for any time as
    // a tap: without swallowing that finger's lift, the tile under it opened the viewer or flipped its selection.
    val claimed = java.util.concurrent.atomic.AtomicBoolean(false)
    return pointerInput(Unit) {
        awaitEachGesture {
            awaitFirstDown(requireUnconsumed = false, pass = androidx.compose.ui.input.pointer.PointerEventPass.Initial)
            do {
                val event = awaitPointerEvent(androidx.compose.ui.input.pointer.PointerEventPass.Initial)
                if (claimed.get()) event.changes.forEach { if (!it.pressed) it.consume() }
            } while (event.changes.any { it.pressed })
            claimed.set(false)
        }
    }.dragGestures(state, order, selection, onChange, onStart, edge, onEdge, claimed, onStep)
}

private fun Modifier.dragGestures(
    state: LazyGridState,
    order: () -> List<String>,
    selection: () -> Set<String>,
    onChange: (Set<String>) -> Unit,
    onStart: () -> Unit,
    edge: Float,
    onEdge: (Float) -> Unit,
    claimed: java.util.concurrent.atomic.AtomicBoolean,
    onStep: () -> Unit,
): Modifier = pointerInput(Unit) {
    var anchor = -1
    var adding = true
    var base = emptySet<String>()
    // Built once per drag: a scan of the whole list for every pointer move was slow on a 40k-photo library.
    var ids = emptyList<String>()
    var positions = emptyMap<String, Int>()
    var lastTo = -2
    fun indexAt(p: Offset): Int {
        val info = state.layoutInfo
        // Item offsets start after the grid's top content padding (the top bar); the finger is in the grid's own
        // coordinates. Without this the finger picked the tile a row below, or nothing over a date header.
        val y = p.y + info.viewportStartOffset
        val key = info.visibleItemsInfo.firstOrNull {
            p.x >= it.offset.x && p.x < it.offset.x + it.size.width && y >= it.offset.y && y < it.offset.y + it.size.height
        }?.key as? String ?: return -1
        return positions[key] ?: -1
    }
    fun select(to: Int) {
        if (anchor < 0 || to < 0 || to == lastTo) return
        // A tick for each tile the finger moves onto, like Google Photos. Not for the first tile: the long press had its own.
        if (lastTo != -2) onStep()
        lastTo = to
        val range = ids.subList(minOf(anchor, to), maxOf(anchor, to) + 1).toSet()
        onChange(if (adding) base + range else base - range)
    }
    detectDragGesturesAfterLongPress(
        onDragStart = { p ->
            ids = order()
            positions = HashMap<String, Int>(ids.size * 2).also { m -> ids.forEachIndexed { i, k -> m[k] = i } }
            lastTo = -2
            anchor = indexAt(p)
            if (anchor < 0) return@detectDragGesturesAfterLongPress
            claimed.set(true)
            onStart()
            base = selection()
            adding = ids[anchor] !in base
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
    val active = speed != 0f
    val current by rememberUpdatedState(speed)
    LaunchedEffect(state, active) {
        if (!active) return@LaunchedEffect
        while (true) {
            if (current != 0f) state.scrollBy(current * 40f)
            delay(16)
        }
    }
}

/** The action row while photos are selected: Share, Favorite and Delete, as in Google Photos. */
@Composable
internal fun SelectionActions(
    chosen: List<GalleryEntry>,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
    album: String? = null,
    inLockedFolder: Boolean = false,
) {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var confirmDelete by remember { mutableStateOf(false) }
    var confirmMoveToLocked by remember { mutableStateOf(false) }
    var sharing by remember { mutableStateOf(false) }
    var addingToAlbum by remember { mutableStateOf(false) }
    val app = context.applicationContext as LelvoApp
    val isPro by app.pro.isPro.collectAsState()
    val inLibrary = chosen.any { it.item?.status == ItemStatus.BackedUp }
    val actions = rememberPhoneActions(onFavorited = { onDone() }, onTrashed = { onDone() })
    val allFavorite = chosen.isNotEmpty() && chosen.all { it.isFavorite }
    var confirmRemoveFromPhone by remember { mutableStateOf<List<GalleryEntry>?>(null) }
    val trash = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartIntentSenderForResult()
    ) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            Messages.show(Messages.Style.Success, "Deleted from Photos on this phone", "Still in Locked Folder and Telegram.")
        }
        confirmRemoveFromPhone = null
        onDone()
    }
    val moveAuth = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            scope.launch {
                app.lockedFolder.lockEntries(chosen, app.store, app.sync) { ids ->
                    scope.launch { app.backup.enqueue(ids) }
                }
                Messages.show(Messages.Style.Success, "Moved to Locked Folder")
                val removable = removableAfterLock(chosen)
                if (removable.isNotEmpty()) confirmRemoveFromPhone = removable else onDone()
            }
        }
        confirmMoveToLocked = false
    }

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
        // Equal columns, like Google Photos: six actions stay on screen, icons on one line, labels under them.
        Row(
            Modifier.fillMaxWidth().padding(vertical = 2.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.Top,
        ) {
            if (inLockedFolder) {
                // Google Photos: no share / album / trash from Locked — only move out.
                Action(R.drawable.ic_lock, "Unlock", enabled = chosen.isNotEmpty()) {
                    scope.launch {
                        app.lockedFolder.unlockEntries(chosen, app.store, app.sync)
                        Messages.show(Messages.Style.Success, "Removed from Locked Folder")
                        onDone()
                    }
                }
            } else {
                Action(R.drawable.ic_send, "Share", enabled = chosen.isNotEmpty() && !sharing) { sharing = true }
                // Phone photos not in the cloud yet: queued as chosen, so they go even with automatic backup off.
                val toBackUp = chosen.filter { it.asset != null && it.badge != BackupBadge.BackedUp }
                if (toBackUp.isNotEmpty()) Action(R.drawable.ic_cloud_upload, "Back up", enabled = true) {
                    scope.launch {
                        val n = app.backup.enqueue(toBackUp.mapNotNull { it.asset?.localId })
                        Messages.show(Messages.Style.Info, if (n == 0) "Already backed up" else "Backing up $n item${if (n == 1) "" else "s"}")
                        if (n > 0) app.startBackup(includeNew = false)
                        onDone()
                    }
                }
                Action(R.drawable.ic_favorite, if (allFavorite) "Unfavorite" else "Favorite", enabled = chosen.any { it.asset != null || it.item?.status == ItemStatus.BackedUp }) {
                    actions.favorite(chosen, !allFavorite)
                }
                // Inside an album: take them out of it; elsewhere: add them to one (the library's albums, iOS "Add to Album").
                if (album != null) Action(R.drawable.ic_library_add, "Remove", enabled = inLibrary) {
                    scope.launch { if (AlbumActions.remove(app, chosen, album)) onDone() }
                } else Action(R.drawable.ic_library_add, "Add to album", enabled = chosen.isNotEmpty()) { addingToAlbum = true }
                if (ProStore.OFFERED) Action(R.drawable.ic_lock, "Lock", enabled = chosen.isNotEmpty()) {
                    if (!isPro) {
                        Messages.show(Messages.Style.Info, "Lelvo Pro", "Locked folder is included with Pro.")
                    } else {
                        confirmMoveToLocked = true
                    }
                }
                Action(R.drawable.ic_delete, "Delete", enabled = chosen.isNotEmpty()) { confirmDelete = true }
            }
        }
    }

    if (confirmDelete) DeleteDialog(chosen, actions, onDismiss = { confirmDelete = false })
    if (addingToAlbum) AddToAlbumDialog(app, chosen.size, onDismiss = { addingToAlbum = false }) { name ->
        scope.launch { if (AlbumActions.add(app, chosen, name)) onDone() }
    }
    if (confirmMoveToLocked) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmMoveToLocked = false },
            title = { Text("Move ${chosen.size} to Locked Folder?") },
            text = {
                Text("They’ll leave your library, search and memories on every Lelvo device. Unlock Locked Folder with your phone lock to see them again. Files stay in your Telegram library.")
            },
            confirmButton = {
                TextButton(onClick = {
                    val intent = confirmLockIntent(context, "Move to Locked folder")
                    if (intent == null) {
                        Messages.show(Messages.Style.Failure, "Set a screen lock in Android Settings to use Locked folder.")
                        confirmMoveToLocked = false
                    } else {
                        moveAuth.launch(intent)
                    }
                }) { Text("Move") }
            },
            dismissButton = {
                TextButton(onClick = { confirmMoveToLocked = false }) { Text("Cancel") }
            },
        )
    }
    confirmRemoveFromPhone?.let { removableEntries ->
        RemoveFromPhoneAfterLockSheet(
            app = app,
            entries = removableEntries,
            onKeep = { confirmRemoveFromPhone = null; onDone() },
            onDeleteFromPhotos = {
                scope.launch {
                    try {
                        val items = mediaItemsAfterLock(removableEntries)
                        val safe = app.freeUpSpace.safeToRemove(items)
                        if (safe.isEmpty()) {
                            Messages.show(Messages.Style.Info, "Nothing deleted from Photos", "Couldn’t confirm every file in Telegram. Try Free Up Space later.")
                            confirmRemoveFromPhone = null
                            onDone()
                            return@launch
                        }
                        if (android.os.Build.VERSION.SDK_INT < 30) {
                            Messages.show(Messages.Style.Info, "Deleting from Photos needs Android 11 or later")
                            confirmRemoveFromPhone = null
                            onDone()
                            return@launch
                        }
                        val uris = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                            app.freeUpSpace.files(safe).map { it.uri }
                        }
                        if (uris.isEmpty()) {
                            Messages.show(Messages.Style.Info, "Nothing deleted from Photos", "Those items are already off this phone.")
                            confirmRemoveFromPhone = null
                            onDone()
                            return@launch
                        }
                        trash.launch(
                            androidx.activity.result.IntentSenderRequest.Builder(
                                android.provider.MediaStore.createTrashRequest(context.contentResolver, uris, true).intentSender
                            ).build()
                        )
                    } catch (e: IllegalStateException) {
                        Messages.show(Messages.Style.Failure, "Couldn't check your library", e.message)
                        confirmRemoveFromPhone = null
                        onDone()
                    }
                }
            },
        )
    }
}

@Composable
private fun RowScope.Action(icon: Int, label: String, enabled: Boolean, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.weight(1f).defaultMinSize(minWidth = 1.dp),
        contentPadding = PaddingValues(horizontal = 0.dp, vertical = 6.dp),
    ) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(painterResource(icon), contentDescription = null)
            Text(
                label,
                style = MaterialTheme.typography.labelSmall,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

