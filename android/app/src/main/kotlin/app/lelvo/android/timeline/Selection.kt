package app.lelvo.android.timeline

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.shell.Messages
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.index.BackupBadge
import app.lelvo.core.index.GalleryEntry
import app.lelvo.data.DemoMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File

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
    val app = context.applicationContext as LelvoApp
    var confirmDelete by remember { mutableStateOf(false) }
    var sharing by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    val favorite = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) onDone()
    }
    val trash = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) {
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            Messages.show(Messages.Style.Success, "Moved to the phone's trash")
            onDone()
        }
    }
    val onPhone = chosen.mapNotNull { it.asset }
    val allFavorite = chosen.isNotEmpty() && chosen.all { it.isFavorite }

    if (sharing) LaunchedEffect(chosen) {
        try {
            share(context, app, chosen)
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
            Action(R.drawable.ic_favorite, if (allFavorite) "Unfavorite" else "Favorite", enabled = onPhone.isNotEmpty()) {
                if (chosen.size > onPhone.size) {
                    Messages.show(Messages.Style.Info, "Only photos on this phone change", "Favorites for photos only in your Telegram library come with sync.")
                }
                if (Build.VERSION.SDK_INT >= 30) {
                    val pi = MediaStore.createFavoriteRequest(context.contentResolver, onPhone.map(app.photos::uri), !allFavorite)
                    favorite.launch(IntentSenderRequest.Builder(pi.intentSender).build())
                } else {
                    Messages.show(Messages.Style.Info, "Favorites need Android 11 or later")
                }
            }
            Action(R.drawable.ic_delete, "Delete", enabled = chosen.isNotEmpty()) { confirmDelete = true }
        }
    }

    if (confirmDelete) {
        val notBacked = onPhone.size - chosen.count { it.asset != null && it.badge == BackupBadge.BackedUp }
        val title = "Delete ${chosen.size} item${if (chosen.size == 1) "" else "s"}?"
        // Short, like Photos. Anything not backed up yet is named first, so "Remove" is never read as safe for it.
        val message = buildList {
            if (notBacked > 0) add("$notBacked ${if (notBacked == 1) "isn't" else "aren't"} backed up yet and will be lost once the phone's trash is emptied.")
            else if (onPhone.isNotEmpty()) add("Removing from this phone keeps your backup.")
            if (chosen.size > onPhone.size) add("Deleting from your Telegram library comes with sync; photos only there stay.")
        }.joinToString(" ")
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(title) },
            text = { Text(message) },
            confirmButton = {
                if (onPhone.isNotEmpty()) TextButton(onClick = {
                    confirmDelete = false
                    // The system asks too, and nothing is deleted if that's cancelled. Android 11+ keeps them in its trash.
                    if (Build.VERSION.SDK_INT >= 30) {
                        val pi = MediaStore.createTrashRequest(context.contentResolver, onPhone.map(app.photos::uri), true)
                        trash.launch(IntentSenderRequest.Builder(pi.intentSender).build())
                    } else {
                        Messages.show(Messages.Style.Info, "Deleting needs Android 11 or later")
                    }
                }) { Text("Remove ${onPhone.size} from this phone", color = Lelvo.colors.red) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
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

/**
 * Shares what the user sees (iOS `shareableFile`): a photo on this phone as it is, a cloud photo's edit or original
 * downloaded first and named like the original, so other apps read its type from the name.
 */
private suspend fun share(context: Context, app: LelvoApp, chosen: List<GalleryEntry>) {
    val cloud = chosen.filter { it.asset == null && it.item != null }
    if (cloud.isNotEmpty()) Messages.progress("Getting ${cloud.size} from Telegram…")
    val uris = withContext(Dispatchers.IO) {
        val dir = File(context.cacheDir, "Share").apply { deleteRecursively(); mkdirs() }
        chosen.mapNotNull { e ->
            e.asset?.let { return@mapNotNull app.photos.uri(it) }
            val item = e.item ?: return@mapNotNull null
            DemoMode.assetUri(item)?.let { return@mapNotNull null }
            val file = app.media.displayed(item)
            val name = (if (app.media.displayedRole(item) == "e") item.editedName else null) ?: item.filename
            val out = File(dir, name.replace(Regex("[/\\\\]"), "_").ifEmpty { "photo" })
            file.copyTo(uniqueName(out), overwrite = false).let { FileProvider.getUriForFile(context, "${context.packageName}.share", it) }
        }
    }
    if (cloud.isNotEmpty()) Messages.show(Messages.Style.Success, "Ready to share")
    if (uris.isEmpty()) return
    val videos = chosen.all { it.isVideo }
    val photos = chosen.none { it.isVideo }
    val intent = Intent(if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
        type = if (videos) "video/*" else if (photos) "image/*" else "*/*"
        if (uris.size == 1) putExtra(Intent.EXTRA_STREAM, uris[0]) else putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList<Uri>(uris))
        clipData = ClipData.newRawUri(null, uris[0]).apply { uris.drop(1).forEach { addItem(ClipData.Item(it)) } }
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, null))
}

/** Two shared photos with the same name (IMG_0001.HEIC from two phones) both go: the second gets " 2". */
private fun uniqueName(f: File): File {
    if (!f.exists()) return f
    val base = f.nameWithoutExtension
    val ext = f.extension.let { if (it.isEmpty()) "" else ".$it" }
    var n = 2
    while (true) { val c = File(f.parentFile, "$base $n$ext"); if (!c.exists()) return c; n++ }
}

