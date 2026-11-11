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
import app.lelvo.core.index.BackupBadge
import app.lelvo.core.index.GalleryEntry
import app.lelvo.data.DemoMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Favorite and trash for photos on this phone, through the system's own prompts (Android 11+), as Google Photos'
 * grid and viewer both use them. Nothing changes unless the user agrees in the system prompt.
 */
class PhoneActions internal constructor(
    private val context: Context,
    private val launchFavorite: (IntentSenderRequest, Boolean) -> Unit,
    private val launchTrash: (IntentSenderRequest) -> Unit,
) {
    private val app = context.applicationContext as LelvoApp

    fun favorite(chosen: List<GalleryEntry>, favorite: Boolean) {
        val onPhone = chosen.mapNotNull { it.asset }
        if (chosen.size > onPhone.size) {
            Messages.show(Messages.Style.Info, "Only photos on this phone change", "Favorites for photos only in your Telegram library come with sync.")
        }
        if (onPhone.isEmpty()) return
        if (Build.VERSION.SDK_INT < 30) {
            Messages.show(Messages.Style.Info, "Favorites need Android 11 or later")
            return
        }
        val pi = MediaStore.createFavoriteRequest(context.contentResolver, onPhone.map(app.photos::uri), favorite)
        launchFavorite(IntentSenderRequest.Builder(pi.intentSender).build(), favorite)
    }

    /** The system asks too, and nothing is deleted if that's cancelled. Android 11+ keeps them in its trash. */
    fun trash(chosen: List<GalleryEntry>) {
        val onPhone = chosen.mapNotNull { it.asset }
        if (onPhone.isEmpty()) return
        if (Build.VERSION.SDK_INT < 30) {
            Messages.show(Messages.Style.Info, "Deleting needs Android 11 or later")
            return
        }
        val pi = MediaStore.createTrashRequest(context.contentResolver, onPhone.map(app.photos::uri), true)
        launchTrash(IntentSenderRequest.Builder(pi.intentSender).build())
    }
}

@Composable
fun rememberPhoneActions(onFavorited: (Boolean) -> Unit = {}, onTrashed: () -> Unit = {}): PhoneActions {
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val favorited by rememberUpdatedState(onFavorited)
    val trashed by rememberUpdatedState(onTrashed)
    val pending = remember { booleanArrayOf(false) }
    val favorite = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) favorited(pending[0])
    }
    val trash = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) {
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            Messages.show(Messages.Style.Success, "Moved to the phone's trash")
            trashed()
        }
    }
    return remember(context) {
        PhoneActions(context, { request, value -> pending[0] = value; favorite.launch(request) }, { trash.launch(it) })
    }
}

/** Asks before deleting, naming anything not backed up first, so "Remove" is never read as safe for it. */
@Composable
fun DeleteDialog(chosen: List<GalleryEntry>, onDismiss: () -> Unit, onRemove: () -> Unit) {
    val onPhone = chosen.count { it.asset != null }
    val notBacked = onPhone - chosen.count { it.asset != null && it.badge == BackupBadge.BackedUp }
    val title = if (chosen.size == 1) "Delete this ${if (chosen[0].isVideo) "video" else "photo"}?" else "Delete ${chosen.size} items?"
    val message = buildList {
        if (notBacked > 0) add(
            if (chosen.size == 1) "It isn't backed up yet and will be lost once the phone's trash is emptied."
            else "$notBacked ${if (notBacked == 1) "isn't" else "aren't"} backed up yet and will be lost once the phone's trash is emptied.",
        )
        else if (onPhone > 0) add("Removing from this phone keeps your backup.")
        if (chosen.size > onPhone) add(
            if (chosen.size == 1) "It's only in your Telegram library. Deleting from there comes with sync."
            else "Deleting from your Telegram library comes with sync; photos only there stay.",
        )
    }.joinToString(" ")
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            if (onPhone > 0) TextButton(onClick = onRemove) {
                Text(if (chosen.size == 1) "Remove from this phone" else "Remove $onPhone from this phone", color = Lelvo.colors.red)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(if (onPhone > 0) "Cancel" else "OK") } },
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
