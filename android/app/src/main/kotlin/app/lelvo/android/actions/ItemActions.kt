package app.lelvo.android.actions

import androidx.compose.runtime.getValue
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.core.content.FileProvider
import app.lelvo.android.LelvoApp
import app.lelvo.android.shell.Messages
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.format.MetaLog
import app.lelvo.core.index.BackupBadge
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.ItemStatus
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import app.lelvo.data.DemoMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Favorite and delete, for photos on this phone and in your Telegram library (iOS `GalleryActions.setFavorite`,
 * `deleteEverywhere`, `deleteFromCloud`). Phone copies change through the system's own prompts (Android 11+), as
 * Google Photos' grid and viewer use them; nothing on the phone changes unless the user agrees there. Library items
 * change in the index at once and reach the other devices as notes.
 */
class PhoneActions internal constructor(
    private val context: Context,
    private val scope: CoroutineScope,
    private val launchFavorite: (IntentSenderRequest, () -> Unit) -> Unit,
    private val launchTrash: (IntentSenderRequest, () -> Unit) -> Unit,
    private val onFavorited: (Boolean) -> Unit,
    /** True when the phone copy stays (deleted from the backup only). */
    private val onDeleted: (keepsPhone: Boolean) -> Unit,
) {
    private val app = context.applicationContext as LelvoApp

    fun favorite(chosen: List<GalleryEntry>, favorite: Boolean) {
        val onPhone = chosen.mapNotNull { it.asset }
        val inLibrary = chosen.mapNotNull { it.item }.filter { it.status == ItemStatus.BackedUp || it.status == ItemStatus.Trashed }
        if (onPhone.isEmpty() && inLibrary.isEmpty()) {
            Messages.show(Messages.Style.Info, "Not backed up yet", "Its favorite goes with its backup.")
            return
        }
        scope.launch {
            // The library first: a refused change stops before the phone prompt.
            if (inLibrary.isNotEmpty() && !tryChange { app.sync.change(inLibrary, MetaLog.Key.Favorite, favorite) }) return@launch
            if (onPhone.isEmpty()) { onFavorited(favorite); return@launch }
            if (Build.VERSION.SDK_INT < 30) {
                Messages.show(Messages.Style.Info, "Favorites on this phone need Android 11 or later")
                onFavorited(favorite)
                return@launch
            }
            val pi = MediaStore.createFavoriteRequest(context.contentResolver, onPhone.map(app.photos::uri), favorite)
            launchFavorite(IntentSenderRequest.Builder(pi.intentSender).build()) {
                // What the phone has now came from Lelvo: the next check mustn't take it for a change made elsewhere.
                scope.launch { app.sync.rememberPhoneFavorites(chosen.filter { it.asset != null }.mapNotNull { it.item?.id }, favorite) }
                onFavorited(favorite)
            }
        }
    }

    /** Removes the phone copies only, through the system prompt. Android 11+ keeps them in its trash. */
    fun removeFromPhone(chosen: List<GalleryEntry>) = trashOnPhone(chosen) {
        Messages.show(Messages.Style.Success, "Moved to the phone's trash", "Backed-up items are still in your Telegram library.")
        onDeleted(false)
    }

    /** Moves the backups to Recently Deleted; copies on this phone stay. */
    fun deleteFromBackup(chosen: List<GalleryEntry>) {
        val items = backedUp(chosen)
        scope.launch {
            val n = moveToTrash(items) ?: return@launch
            Messages.show(Messages.Style.Success, "Deleted $n from your backup",
                "Copies on this phone stay. You can get the backups back from Collections › Recently Deleted for 30 days.", seconds = 5.0)
            onDeleted(true)
        }
    }

    /**
     * Phone copies first, through the system prompt: if the user cancels it, nothing is deleted anywhere. Then the
     * backups go to Recently Deleted.
     */
    fun deleteEverywhere(chosen: List<GalleryEntry>) {
        val items = backedUp(chosen)
        val cloudThen: () -> Unit = {
            scope.launch {
                if (items.isNotEmpty()) {
                    moveToTrash(items) ?: return@launch
                    Messages.show(Messages.Style.Success, "Deleted ${chosen.size} item${if (chosen.size == 1) "" else "s"}",
                        "You can get backups back from Collections › Recently Deleted for 30 days.", seconds = 5.0)
                } else {
                    Messages.show(Messages.Style.Success, "Moved to the phone's trash")
                }
                onDeleted(false)
            }
        }
        if (chosen.any { it.asset != null }) trashOnPhone(chosen, cloudThen) else cloudThen()
    }

    private fun backedUp(chosen: List<GalleryEntry>) = chosen.mapNotNull { it.item }.filter { it.status == ItemStatus.BackedUp }

    /** Null when nothing moved, after saying why. */
    private suspend fun moveToTrash(items: List<app.lelvo.core.index.LibraryItem>): Int? = try {
        withContext(Dispatchers.IO) { app.sync.deleteFromCloud(items) }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Messages.show(Messages.Style.Failure, "Nothing was deleted from your backup", "${e.message ?: "Check your connection."} Try again.", seconds = 5.0)
        null
    }

    private suspend fun tryChange(block: suspend () -> Int): Boolean = try {
        withContext(Dispatchers.IO) { block() }
        true
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Messages.show(Messages.Style.Failure, "Favorite not changed", e.message ?: "Try again.", seconds = 5.0)
        false
    }

    private fun trashOnPhone(chosen: List<GalleryEntry>, then: () -> Unit) {
        val onPhone = chosen.mapNotNull { it.asset }
        if (onPhone.isEmpty()) return
        if (Build.VERSION.SDK_INT < 30) {
            Messages.show(Messages.Style.Info, "Deleting needs Android 11 or later")
            return
        }
        val pi = MediaStore.createTrashRequest(context.contentResolver, onPhone.map(app.photos::uri), true)
        launchTrash(IntentSenderRequest.Builder(pi.intentSender).build(), then)
    }
}

@Composable
fun rememberPhoneActions(onFavorited: (Boolean) -> Unit = {}, onTrashed: (keepsPhone: Boolean) -> Unit = {}): PhoneActions {
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val favorited by rememberUpdatedState(onFavorited)
    val trashed by rememberUpdatedState(onTrashed)
    // What to do once the system prompt says yes; nothing when it's cancelled.
    val pending = remember { arrayOfNulls<() -> Unit>(2) }
    val favorite = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) pending[0]?.invoke()
        pending[0] = null
    }
    val trash = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) {
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            pending[1]?.invoke()
        }
        pending[1] = null
    }
    return remember(context) {
        PhoneActions(
            context, scope,
            { request, then -> pending[0] = then; favorite.launch(request) },
            { request, then -> pending[1] = then; trash.launch(request) },
            onFavorited = { favorited(it) },
            onDeleted = { keepsPhone -> haptics.performHapticFeedback(HapticFeedbackType.Confirm); trashed(keepsPhone) },
        )
    }
}

/**
 * Asks how to delete, like iOS: remove from this phone, delete from the backup only (keeps the phone copy), or
 * everywhere. Anything not backed up is named first, so "Remove" is never read as safe for it.
 */
@Composable
fun DeleteDialog(chosen: List<GalleryEntry>, actions: PhoneActions, onDismiss: () -> Unit) {
    val onPhone = chosen.count { it.asset != null }
    val backedUp = chosen.count { it.item?.status == ItemStatus.BackedUp }
    val notBacked = onPhone - chosen.count { it.asset != null && it.badge == BackupBadge.BackedUp }
    val title = if (chosen.size == 1) "Delete this ${if (chosen[0].isVideo) "video" else "photo"}?" else "Delete ${chosen.size} items?"
    val message = buildList {
        if (notBacked > 0) add(
            if (chosen.size == 1) "It isn't backed up yet and will be lost once the phone's trash is emptied."
            else "$notBacked ${if (notBacked == 1) "isn't" else "aren't"} backed up yet and will be lost once the phone's trash is emptied.",
        )
        else if (onPhone > 0) add("Remove from this phone keeps your backup.")
        if (backedUp > 0) add("Deleted backups stay in Recently Deleted for 30 days.")
    }.joinToString(" ")
    val red = Lelvo.colors.red
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                Text(message)
                Spacer(Modifier.height(12.dp))
                @Composable fun Choice(label: String, onClick: () -> Unit) = TextButton(
                    onClick = { onDismiss(); onClick() }, modifier = Modifier.fillMaxWidth(),
                ) { Text(label, color = red, modifier = Modifier.fillMaxWidth()) }
                if (onPhone > 0) Choice(if (chosen.size == 1) "Remove from this phone" else "Remove $onPhone from this phone") { actions.removeFromPhone(chosen) }
                // Keeps the copy on this phone: the only way to take something out of the backup but keep it here.
                if (backedUp > 0 && onPhone > 0) Choice(if (chosen.size == 1) "Delete from backup only" else "Delete $backedUp from backup only") {
                    actions.deleteFromBackup(chosen)
                }
                if (backedUp > 0 || onPhone > 0) Choice("Delete everywhere") { actions.deleteEverywhere(chosen) }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(if (onPhone > 0 || backedUp > 0) "Cancel" else "OK") } },
    )
}

/**
 * Shares what the user sees (iOS `shareableFile`): a photo on this phone as it is, a cloud photo's edit or original
 * downloaded first and named like the original, so other apps read its type from the name. [original] shares the
 * untouched original of an edited cloud photo (iOS "Share Original").
 */
suspend fun shareEntries(context: Context, chosen: List<GalleryEntry>, original: Boolean = false) {
    val app = context.applicationContext as LelvoApp
    val cloud = chosen.filter { it.asset == null && it.item != null }
    if (cloud.isNotEmpty()) Messages.progress(if (cloud.size == 1) "Getting it from Telegram…" else "Getting ${cloud.size} from Telegram…")
    val uris = withContext(Dispatchers.IO) {
        val dir = File(context.cacheDir, "Share").apply { deleteRecursively(); mkdirs() }
        chosen.mapNotNull { e ->
            e.asset?.let { return@mapNotNull app.photos.uri(it) }
            val item = e.item ?: return@mapNotNull null
            DemoMode.assetUri(item)?.let { return@mapNotNull null }
            val role = if (original) "o" else app.media.displayedRole(item)
            val file = app.media.file(item, role)
            val name = (if (role == "e") item.editedName else null) ?: item.filename
            val out = File(dir, name.replace(Regex("[/\\\\]"), "_").ifEmpty { "photo" })
            file.copyTo(uniqueName(out), overwrite = false).let { FileProvider.getUriForFile(context, "${context.packageName}.share", it) }
        }
    }
    if (cloud.isNotEmpty()) Messages.dismiss()
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
