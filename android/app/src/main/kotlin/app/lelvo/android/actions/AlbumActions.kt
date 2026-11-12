package app.lelvo.android.actions

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.shell.Messages
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.format.MetaLog
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Albums in your Telegram library (iOS `AddToAlbumView`, `GalleryActions.addToAlbum` and `deleteAlbum`). Android's
 * folders aren't albums, so an album here is the library's own: a note tells every device, and the iPhone puts the
 * photo in that album in Photos when it saves it. Only backed-up items can join; nothing is downloaded or deleted.
 */
object AlbumActions {
    /** The library's album names, as Collections lists them. */
    suspend fun names(app: LelvoApp): List<String> = withContext(Dispatchers.IO) {
        app.store.allItems().filter { it.status == ItemStatus.BackedUp }.flatMap { it.albums }
            .distinct().sortedWith(String.CASE_INSENSITIVE_ORDER)
    }

    suspend fun add(app: LelvoApp, chosen: List<GalleryEntry>, rawName: String): Boolean {
        val name = MetaLog.albumName(rawName) ?: return false
        val items = inLibrary(chosen)
        val waiting = chosen.size - items.size
        if (items.isEmpty()) {
            Messages.show(Messages.Style.Info, "Back up first", "Only backed-up photos can join an album in your Telegram library.", seconds = 5.0)
            return false
        }
        return guarded("Couldn't add to the album") {
            app.sync.change(items, MetaLog.Key.Album(name), true)
            Messages.show(
                Messages.Style.Success, "Added ${items.size} to “$name”",
                if (waiting > 0) "$waiting not backed up yet ${if (waiting == 1) "isn't" else "aren't"} in it. Back ${if (waiting == 1) "it" else "them"} up, then add ${if (waiting == 1) "it" else "them"}." else null,
                seconds = if (waiting > 0) 5.0 else 3.5,
            )
        }
    }

    /** Like Delete Album in Photos: the album goes from Lelvo on every device; no photo is deleted. */
    suspend fun delete(app: LelvoApp, name: String): Boolean {
        val members = withContext(Dispatchers.IO) { app.store.allItems().filter { name in it.albums } }
        return guarded("Couldn't delete the album") {
            app.sync.change(members, MetaLog.Key.Album(name), false)
            Messages.show(Messages.Style.Success, "Deleted “$name”", "Its photos stay in your library.")
        }
    }

    /** Takes the chosen photos out of the album; they stay in the library. */
    suspend fun remove(app: LelvoApp, chosen: List<GalleryEntry>, name: String): Boolean {
        val items = inLibrary(chosen).filter { name in it.albums }
        if (items.isEmpty()) return false
        return guarded("Couldn't remove from the album") {
            app.sync.change(items, MetaLog.Key.Album(name), false)
            Messages.show(Messages.Style.Success, "Removed ${items.size} from “$name”")
        }
    }

    private fun inLibrary(chosen: List<GalleryEntry>): List<LibraryItem> =
        chosen.mapNotNull { it.item }.filter { it.status == ItemStatus.BackedUp || it.status == ItemStatus.Trashed }.distinctBy { it.id }

    private suspend fun guarded(failTitle: String, work: suspend () -> Unit): Boolean = try {
        withContext(Dispatchers.IO) { work() }
        true
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Messages.show(Messages.Style.Failure, failTitle, e.message ?: "Try again.", seconds = 5.0)
        false
    }
}

/** Pick an album or make a new one, like Google Photos' "Add to album". */
@Composable
fun AddToAlbumDialog(app: LelvoApp, count: Int, onDismiss: () -> Unit, onChosen: (String) -> Unit) {
    val names by produceState<List<String>?>(null) { value = AlbumActions.names(app) }
    var creating by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    if (creating) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("New album") },
            text = {
                OutlinedTextField(newName, { newName = it }, label = { Text("Title") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            },
            confirmButton = {
                TextButton(onClick = { MetaLog.albumName(newName)?.let { onDismiss(); onChosen(it) } }, enabled = MetaLog.albumName(newName) != null) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        )
        return
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add to album") },
        text = {
            Column {
                Text(
                    "$count item${if (count == 1) "" else "s"}. Albums are kept in your Telegram library, so your other devices show them too.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                LazyColumn(Modifier.heightIn(max = 320.dp).padding(top = 8.dp)) {
                    item("new") {
                        ListItem(
                            headlineContent = { Text("New album", color = Lelvo.colors.accent) },
                            leadingContent = { Icon(painterResource(R.drawable.ic_add_circle), null, tint = Lelvo.colors.accent) },
                            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                            modifier = Modifier.clickable { creating = true },
                        )
                    }
                    items(names.orEmpty(), key = { it }) { name ->
                        ListItem(
                            headlineContent = { Text(name) },
                            leadingContent = { Icon(painterResource(R.drawable.ic_library_add), null) },
                            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                            modifier = Modifier.clickable { onDismiss(); onChosen(name) },
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
