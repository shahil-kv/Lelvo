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
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import app.lelvo.android.R
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
 * everywhere. A sheet, as Google Photos asks, with one line under each choice saying what stays, so no two choices
 * look alike. Choices that would do the same thing are left out: with nothing backed up, "everywhere" is just this
 * phone; with nothing on the phone, it's just the backup. Anything not backed up is named first, so "Remove" is
 * never read as safe for it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeleteDialog(chosen: List<GalleryEntry>, actions: PhoneActions, onDismiss: () -> Unit) {
    val onPhone = chosen.count { it.asset != null }
    val backedUp = chosen.count { it.item?.status == ItemStatus.BackedUp }
    val notBacked = onPhone - chosen.count { it.asset != null && it.badge == BackupBadge.BackedUp }
    val one = chosen.size == 1
    val what = if (one) "this ${if (chosen[0].isVideo) "video" else "photo"}" else "${"%,d".format(chosen.size)} items"
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    // Closes the sheet first, so the system prompt for phone copies doesn't open behind it.
    fun choose(action: () -> Unit) {
        scope.launch { sheet.hide() }.invokeOnCompletion { onDismiss(); action() }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet) {
        Column(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
            Text("Delete $what?", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.padding(horizontal = 24.dp))
            if (notBacked > 0) {
                Row(Modifier.padding(start = 24.dp, end = 24.dp, top = 12.dp), verticalAlignment = Alignment.Top) {
                    Icon(painterResource(R.drawable.ic_cloud_off), contentDescription = null, tint = Lelvo.colors.orange,
                        modifier = Modifier.padding(top = 2.dp).size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(
                        if (one) "It isn't backed up yet. Once it's gone from this phone's trash, it can't be brought back."
                        else "${"%,d".format(notBacked)} ${if (notBacked == 1) "isn't" else "aren't"} backed up yet. Once they're gone from this phone's trash, they can't be brought back.",
                        style = MaterialTheme.typography.bodyMedium, color = Lelvo.colors.orange,
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            when {
                onPhone == 0 && backedUp == 0 -> {
                    Text(
                        if (one) "It's still backing up. You can delete it once it's in your Telegram library."
                        else "These are still backing up. You can delete them once they're in your Telegram library.",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                    )
                }
                backedUp == 0 -> DeleteChoice(R.drawable.ic_delete, if (one) "Delete from this phone" else "Delete ${"%,d".format(onPhone)} from this phone",
                    "Moves to this phone's trash. Nothing is in your Telegram library yet.", destructive = true) { choose { actions.removeFromPhone(chosen) } }
                onPhone == 0 -> DeleteChoice(R.drawable.ic_delete, if (one) "Delete from backup" else "Delete ${"%,d".format(backedUp)} from backup",
                    "Removed from your Telegram library. You can get ${if (one) "it" else "them"} back from Recently Deleted for 30 days.",
                    destructive = true) { choose { actions.deleteEverywhere(chosen) } }
                else -> {
                    DeleteChoice(R.drawable.ic_phone, if (one) "Remove from this phone" else "Remove ${"%,d".format(onPhone)} from this phone",
                        if (notBacked > 0) "Backed-up items stay in your Telegram library." else "Frees space here. Your backup stays in your Telegram library.",
                    ) { choose { actions.removeFromPhone(chosen) } }
                    DeleteChoice(R.drawable.ic_cloud_off, if (one) "Delete from backup only" else "Delete ${"%,d".format(backedUp)} from backup only",
                        "Keeps the copy on this phone. The backup goes to Recently Deleted for 30 days.",
                    ) { choose { actions.deleteFromBackup(chosen) } }
                    DeleteChoice(R.drawable.ic_delete, "Delete everywhere",
                        "From this phone and your Telegram library. Backups stay in Recently Deleted for 30 days.", destructive = true,
                    ) { choose { actions.deleteEverywhere(chosen) } }
                }
            }
            TextButton(onClick = { choose {} }, modifier = Modifier.align(Alignment.End).padding(end = 16.dp, top = 4.dp)) {
                Text(if (onPhone == 0 && backedUp == 0) "OK" else "Cancel")
            }
        }
    }
}

@Composable
private fun DeleteChoice(icon: Int, title: String, detail: String, destructive: Boolean = false, onClick: () -> Unit) {
    val tint = if (destructive) Lelvo.colors.red else MaterialTheme.colorScheme.onSurface
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick, role = Role.Button).padding(horizontal = 24.dp, vertical = 12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(painterResource(icon), contentDescription = null, tint = tint, modifier = Modifier.padding(top = 2.dp).size(22.dp))
        Spacer(Modifier.width(16.dp))
        Column {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = tint)
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/**
 * Shares what the user sees (iOS `shareableFile`): a photo on this phone as it is, a cloud photo's edit or original
 * downloaded first and named like the original, so other apps read its type from the name. [original] shares the
 * untouched original of an edited cloud photo (iOS "Share Original").
 */
suspend fun shareEntries(context: Context, chosen: List<GalleryEntry>, original: Boolean = false) {
    val uris = shareableUris(context, chosen, original, folder = "Share")
    if (uris.isEmpty()) return
    val videos = chosen.all { it.isVideo }
    val photos = chosen.none { it.isVideo }
    val intent = Intent(if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
        type = if (videos) "video/*" else if (photos) "image/*" else "*/*"
        if (uris.size == 1) putExtra(Intent.EXTRA_STREAM, uris[0]) else putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList<Uri>(uris))
        clipData = ClipData.newRawUri(null, uris[0]).apply { uris.drop(1).forEach { addItem(ClipData.Item(it)) } }
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, null).apply {
        // Lelvo's own "Back up" share target makes no sense for photos that are already in Lelvo.
        putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, arrayOf(android.content.ComponentName(context, app.lelvo.android.ShareActivity::class.java)))
    })
}

/**
 * Copy (like Ctrl+C): puts the photos on the clipboard, so they paste into a chat, an email or an AI app. A cloud
 * photo is downloaded first, like Share. Android 13 and later confirm the copy themselves.
 */
suspend fun copyEntries(context: Context, chosen: List<GalleryEntry>) {
    // A cloud photo is written out to be copied; never fill the phone with those copies.
    if (context.cacheDir.usableSpace < MIN_FREE_FOR_COPIES) {
        Messages.show(Messages.Style.Failure, "Not enough space to copy", "Free up some space on this phone, then try again.")
        return
    }
    val uris = shareableUris(context, chosen, original = false, folder = "Copy")
    if (uris.isEmpty()) return
    val resolver = context.contentResolver
    val clip = ClipData.newUri(resolver, if (uris.size == 1) "Photo" else "Photos", uris[0])
    uris.drop(1).forEach { clip.addItem(resolver, ClipData.Item(it)) }
    context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(clip)
    if (android.os.Build.VERSION.SDK_INT < 33) {
        Messages.show(Messages.Style.Success, if (uris.size == 1) "Copied" else "Copied ${uris.size} items")
    }
}

private const val MIN_FREE_FOR_COPIES = 1L shl 30

/** A phone photo's own uri, a cloud one downloaded into [folder] first (emptied each time) and named like the original. */
private suspend fun shareableUris(context: Context, chosen: List<GalleryEntry>, original: Boolean, folder: String): List<Uri> {
    val app = context.applicationContext as LelvoApp
    val cloud = chosen.filter { it.asset == null && it.item != null }
    if (cloud.isNotEmpty()) Messages.progress(if (cloud.size == 1) "Getting it from Telegram…" else "Getting ${cloud.size} from Telegram…")
    val uris = withContext(Dispatchers.IO) {
        val dir = File(context.cacheDir, folder).apply { deleteRecursively(); mkdirs() }
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
    return uris
}

/** Two shared photos with the same name (IMG_0001.HEIC from two phones) both go: the second gets " 2". */
private fun uniqueName(f: File): File {
    if (!f.exists()) return f
    val base = f.nameWithoutExtension
    val ext = f.extension.let { if (it.isEmpty()) "" else ".$it" }
    var n = 2
    while (true) { val c = File(f.parentFile, "$base $n$ext"); if (!c.exists()) return c; n++ }
}
