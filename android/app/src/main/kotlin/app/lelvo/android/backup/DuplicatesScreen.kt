package app.lelvo.android.backup

import android.app.Activity
import android.os.Build
import android.provider.MediaStore
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.android.shell.Messages
import app.lelvo.core.backup.CloudDuplicateGroup
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.support.AppLog
import app.lelvo.core.index.ItemStatus
import app.lelvo.data.backup.SimilarPhotosService
import app.lelvo.data.backup.Duplicates
import coil3.compose.AsyncImage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Extra copies in the Telegram library, identical photos on this phone and similar photos (iOS `DuplicatesView`).
 * Nothing is removed without a tap; one copy of everything always stays.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DuplicatesScreen(app: LelvoApp, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val service = app.duplicates
    var messages by remember { mutableStateOf<List<Long>>(emptyList()) }
    var cloud by remember { mutableStateOf<List<CloudDuplicateGroup>>(emptyList()) }
    var phone by remember { mutableStateOf<List<Duplicates.PhoneGroup>>(emptyList()) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var loading by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var confirmCloud by remember { mutableStateOf(false) }
    var reload by remember { mutableIntStateOf(0) }
    var asked by remember { mutableStateOf<List<String>>(emptyList()) }
    var similar by remember { mutableStateOf<List<SimilarPhotosService.Group>>(emptyList()) }
    var similarProgress by remember { mutableStateOf<Pair<Int, Int>?>(0 to 0) }
    var similarPass by remember { mutableIntStateOf(0) }
    var chosenSimilar by remember { mutableStateOf(setOf<String>()) }
    var confirmSimilar by remember { mutableStateOf(false) }

    // Runs while the page is open: leaving Duplicates stops the comparing.
    LaunchedEffect(similarPass) {
        similarProgress = 0 to 0
        val found = app.similar.find { done, total -> similarProgress = done to total }
        similar = found
        chosenSimilar = chosenSimilar intersect found.flatMap { g -> g.entries.map { it.id } }.toSet()
        similarProgress = null
    }
    // Photos on this phone go to its trash first; if the prompt is cancelled, nothing is deleted anywhere.
    fun deleteCloudOnly(chosen: List<GalleryEntry>, onPhone: Int) = scope.launch {
        val cloudOnly = chosen.filter { it.asset == null }.mapNotNull { it.item }
        try {
            if (cloudOnly.isNotEmpty()) withContext(Dispatchers.IO) { app.sync.deleteFromCloud(cloudOnly) }
            Messages.show(Messages.Style.Success, "Deleted ${chosen.size} similar photo${if (chosen.size == 1) "" else "s"}",
                if (cloudOnly.isNotEmpty()) "You can get backups back from Collections › Recently Deleted for 30 days." else null)
            AppLog.info("Deleted $onPhone similar photos from this phone and moved ${cloudOnly.size} to Recently Deleted")
            chosenSimilar = emptySet()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Messages.show(Messages.Style.Failure, "Couldn't delete", e.message ?: "Check your connection and try again.")
        }
        similarPass++
    }
    var pendingSimilar by remember { mutableStateOf<List<GalleryEntry>>(emptyList()) }
    val trashSimilar = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        val chosen = pendingSimilar
        pendingSimilar = emptyList()
        if (r.resultCode == Activity.RESULT_OK) deleteCloudOnly(chosen, chosen.count { it.asset != null })
    }

    LaunchedEffect(reload) {
        messages = service.messageDuplicates()
        cloud = service.cloudGroups()
        phone = service.phoneGroups()
        selected = selected intersect phone.flatMap { g -> g.copies.map { it.localId } }.toSet()
        loading = false
    }
    val trash = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        val ids = asked
        if (r.resultCode == Activity.RESULT_OK) scope.launch {
            val n = service.forgetDeletedCopies(ids)
            Messages.show(Messages.Style.Success, "Moved $n cop${if (n == 1) "y" else "ies"} to the phone's trash")
            selected = emptySet()
            reload++
        }
    }

    Scaffold(modifier, topBar = {
        TopAppBar(title = { Text("Extra copies and duplicates") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } })
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            if (loading) item("loading") {
                Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else if (messages.isEmpty() && cloud.isEmpty() && phone.isEmpty() && similar.isEmpty() && similarProgress == null) item("empty") {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No duplicates", style = MaterialTheme.typography.titleMedium)
                    Text("Nothing is stored twice in your library or on this phone.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (messages.isNotEmpty() || cloud.isNotEmpty()) {
                item("cloudHeader") { Header("In your Telegram library") }
                if (messages.isNotEmpty()) item("messages") {
                    ListItem(headlineContent = { Text("${messages.size} extra upload${if (messages.size == 1) "" else "s"} of files that are already stored") })
                }
                items(cloud, key = { it.keep.id }) { g ->
                    ListItem(
                        headlineContent = { Text(g.keep.filename, maxLines = 1) },
                        supportingContent = { Text("Stored ${g.extras.size + 1} times · ${Formatter.formatShortFileSize(context, g.wastedBytes)} extra") },
                    )
                }
                item("cloudAction") {
                    Button(
                        onClick = { confirmCloud = true }, enabled = !busy,
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    ) { Text("Remove extra copies from Telegram") }
                    Note("One copy of each always stays, and photos on this phone stay linked to it.")
                }
            }
            if (phone.isNotEmpty()) {
                item("phoneHeader") { HorizontalDivider(); Header("On this phone") }
                items(phone, key = { it.item.id }) { g ->
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(g.item.filename, style = MaterialTheme.typography.bodyMedium)
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            g.original?.let { o -> item(o.localId) { Tile(o.uri, label = "Kept", selected = false, onClick = null) } }
                            items(g.copies, key = { it.localId }) { c ->
                                val on = c.localId in selected
                                Tile(c.uri, label = null, selected = on) { selected = if (on) selected - c.localId else selected + c.localId }
                            }
                        }
                    }
                }
                item("phoneActions") {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                        TextButton(onClick = { selected = phone.flatMap { g -> g.copies.map { it.localId } }.toSet() }) { Text("Select all copies") }
                        TextButton(
                            enabled = selected.isNotEmpty() && Build.VERSION.SDK_INT >= 30,
                            onClick = {
                                val uris = phone.flatMap { it.copies }.filter { it.localId in selected }
                                asked = uris.map { it.localId }
                                val pi = MediaStore.createTrashRequest(context.contentResolver, uris.map { it.uri }, true)
                                trash.launch(IntentSenderRequest.Builder(pi.intentSender).build())
                            },
                        ) { Text("Delete ${selected.size} from this phone", color = MaterialTheme.colorScheme.error) }
                    }
                    Note("Identical copies of photos that are already backed up. Deleting a copy moves it to the phone's trash; the backup isn't affected.")
                }
            }
            similarProgress?.let { (done, total) ->
                if (!loading) item("similarProgress") {
                    HorizontalDivider(); Header("Similar photos")
                    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("Comparing photos taken close together…", style = MaterialTheme.typography.bodyMedium)
                        if (total > 0) {
                            LinearProgressIndicator(progress = { done / total.toFloat() }, modifier = Modifier.fillMaxWidth())
                            Text("$done of $total", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        } else {
                            LinearProgressIndicator(Modifier.fillMaxWidth())
                        }
                    }
                }
            }
            if (similarProgress == null && similar.isNotEmpty()) {
                item("similarHeader") { HorizontalDivider(); Header("Similar photos") }
                items(similar, key = { "s_" + it.id }) { g ->
                    LazyRow(Modifier.padding(vertical = 6.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(g.entries, key = { it.id }) { e ->
                            val on = e.id in chosenSimilar
                            SimilarTile(app, e, isBest = e.id == g.best, selected = on) {
                                chosenSimilar = if (on) chosenSimilar - e.id else chosenSimilar + e.id
                            }
                        }
                    }
                }
                item("similarActions") {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                        // Photos not backed up are never chosen for you: select them one by one if you mean it.
                        TextButton(onClick = {
                            chosenSimilar = similar.flatMap { g -> g.entries.filter { it.id != g.best && !it.notBackedUp }.map { it.id } }.toSet()
                        }) { Text("Select extras to delete") }
                        TextButton(enabled = chosenSimilar.isNotEmpty(), onClick = { confirmSimilar = true }) {
                            Text("Delete ${chosenSimilar.size}", color = if (chosenSimilar.isEmpty()) androidx.compose.ui.graphics.Color.Unspecified else MaterialTheme.colorScheme.error)
                        }
                    }
                    Note("Photos taken moments apart that look almost the same. The suggested one to keep is marked Best. " +
                        "Photos on this phone go to the phone's trash; photos only in your Telegram library go to Recently Deleted in Lelvo.")
                }
            }
        }
    }
    if (confirmSimilar) {
        val chosen = similar.flatMap { it.entries }.filter { it.id in chosenSimilar }
        val unsafe = chosen.count { it.notBackedUp }
        AlertDialog(
            onDismissRequest = { confirmSimilar = false },
            title = { Text("Delete ${chosen.size} similar photo${if (chosen.size == 1) "" else "s"}?") },
            text = {
                Text(if (unsafe > 0) "$unsafe of these ${if (unsafe == 1) "is" else "are"} not backed up yet and ${if (unsafe == 1) "is" else "are"} lost once the phone's trash is emptied."
                else "Photos on this phone go to the phone's trash; photos only in your Telegram library go to Recently Deleted in Lelvo.")
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmSimilar = false
                    val onPhone = chosen.filter { it.asset != null }
                    when {
                        onPhone.isEmpty() -> deleteCloudOnly(chosen, 0)
                        Build.VERSION.SDK_INT < 30 -> Messages.show(Messages.Style.Info, "Deleting needs Android 11 or later")
                        else -> {
                            pendingSimilar = chosen
                            val pi = MediaStore.createTrashRequest(context.contentResolver, onPhone.map { app.photos.uri(it.asset!!) }, true)
                            trashSimilar.launch(IntentSenderRequest.Builder(pi.intentSender).build())
                        }
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmSimilar = false }) { Text("Cancel") } },
        )
    }
    if (confirmCloud) AlertDialog(
        onDismissRequest = { confirmCloud = false },
        title = { Text("Remove extra copies?") },
        text = { Text("Deletes only the duplicate messages. One copy of every photo and video stays in your library.") },
        confirmButton = {
            TextButton(onClick = {
                confirmCloud = false
                busy = true
                scope.launch {
                    try {
                        if (messages.isNotEmpty()) service.removeMessageDuplicates()
                        val n = service.removeCloudDuplicates(cloud)
                        Messages.show(Messages.Style.Success, "Removed extra copies", if (n > 0) "$n duplicate item${if (n == 1) "" else "s"}" else null)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Messages.show(Messages.Style.Failure, "Couldn't remove them", e.message)
                    } finally {
                        busy = false
                        reload++
                    }
                }
            }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(onClick = { confirmCloud = false }) { Text("Cancel") } },
    )
}

@Composable
private fun Tile(uri: android.net.Uri, label: String?, selected: Boolean, onClick: (() -> Unit)?) {
    Box(
        Modifier.size(88.dp).clip(RoundedCornerShape(8.dp))
            .then(if (selected) Modifier.border(3.dp, MaterialTheme.colorScheme.error, RoundedCornerShape(8.dp)) else Modifier)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            // A selected copy is one to delete, so it says so.
            .semantics { contentDescription = (label ?: "Copy") + if (selected) ", will be deleted" else "" },
    ) {
        AsyncImage(PhoneThumbnail(uri), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        label?.let {
            Text(it, style = MaterialTheme.typography.labelSmall, color = androidx.compose.ui.graphics.Color.White,
                modifier = Modifier.align(Alignment.BottomStart).padding(4.dp))
        }
        if (selected) Icon(painterResource(R.drawable.ic_delete), null, tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(18.dp))
    }
}

/** On this phone and not safely in the library: never picked for deleting automatically. */
private val GalleryEntry.notBackedUp: Boolean get() = asset != null && item?.status != ItemStatus.BackedUp

@Composable
private fun SimilarTile(app: LelvoApp, entry: GalleryEntry, isBest: Boolean, selected: Boolean, onClick: () -> Unit) {
    val model: Any? = entry.asset?.let { PhoneThumbnail(app.photos.uri(it)) } ?: entry.item?.let { CloudThumbnail(it) }
    val description = buildString {
        append(if (isBest) "Best photo" else "Photo")
        if (entry.notBackedUp) append(", not backed up")
        if (entry.asset == null) append(", only in the cloud")
        if (selected) append(", will be deleted")
    }
    Box(
        Modifier.size(88.dp).clip(RoundedCornerShape(8.dp))
            .then(if (selected) Modifier.border(3.dp, MaterialTheme.colorScheme.error, RoundedCornerShape(8.dp)) else Modifier)
            .clickable(onClick = onClick)
            .semantics { contentDescription = description },
    ) {
        AsyncImage(model, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        val chip = Modifier.align(Alignment.BottomStart).padding(4.dp)
            .background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.6f), RoundedCornerShape(50)).padding(horizontal = 6.dp, vertical = 2.dp)
        when {
            isBest -> Text("Best", style = MaterialTheme.typography.labelSmall, color = androidx.compose.ui.graphics.Color.White, modifier = chip)
            entry.notBackedUp -> Icon(painterResource(R.drawable.ic_cloud_off), null, tint = androidx.compose.ui.graphics.Color.White, modifier = chip.size(14.dp))
            entry.asset == null -> Icon(painterResource(R.drawable.ic_cloud), null, tint = androidx.compose.ui.graphics.Color.White, modifier = chip.size(14.dp))
        }
        // A selected photo here is one to delete, so it says so: a tick next to "Best" would read as "keep these".
        if (selected) Icon(painterResource(R.drawable.ic_delete), null, tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(18.dp))
    }
}
