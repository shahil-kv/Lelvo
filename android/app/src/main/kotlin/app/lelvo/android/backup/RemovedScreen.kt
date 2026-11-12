package app.lelvo.android.backup

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.android.shell.Messages
import app.lelvo.core.backup.BackupCounts
import app.lelvo.core.index.ItemStatus
import app.lelvo.data.backup.PhoneFile
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Photos deleted from the backup and still on this phone (iOS `RemovedFromBackupView`): Back up now and automatic
 * backup skip them until the user chooses to back them up here.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemovedScreen(app: LelvoApp, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val scope = rememberCoroutineScope()
    var photos by remember { mutableStateOf<List<PhoneFile>?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    LaunchedEffect(reload) {
        photos = withContext(Dispatchers.IO) {
            val all = app.backup.phone.all()
            val ids = BackupCounts.removedFromBackup(
                app.store.items(ItemStatus.Trashed), app.store.offBackupLocalIds(), app.store.knownLocalIds(), all.map { it.localId }.toHashSet(),
            ).toHashSet()
            all.filter { it.localId in ids }
        }
    }
    fun backUp(chosen: List<PhoneFile>) = scope.launch {
        val n = app.backup.enqueue(chosen.map { it.localId })
        if (n > 0) {
            Messages.show(Messages.Style.Info, "Backing up $n item${if (n == 1) "" else "s"}")
            app.startBackup(includeNew = false)
        } else {
            // Still in Recently Deleted: backing it up again is recovering it (iOS `BackupEngine`), with its note.
            val recovered = try {
                withContext(Dispatchers.IO) {
                    chosen.mapNotNull { app.store.itemForPhone(it.localId) }.filter { it.status == ItemStatus.Trashed }.count { app.sync.recoverForBackup(it) }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                Messages.show(Messages.Style.Failure, "Couldn't recover", e.message ?: "Try again.", seconds = 5.0)
                -1
            }
            if (recovered > 0) Messages.show(Messages.Style.Success, if (recovered == 1) "Recovered 1 item" else "Recovered $recovered items", "It's back in your Telegram library.")
            else if (recovered == 0) Messages.show(Messages.Style.Info, "Already backed up")
        }
        reload++
    }

    Scaffold(modifier, topBar = {
        TopAppBar(title = { Text("Removed from backup") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } })
    }) { padding ->
        val list = photos
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            if (list != null && list.isEmpty()) item("empty") {
                Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Nothing removed", style = MaterialTheme.typography.titleMedium)
                    Text("Photos you delete from your backup and keep on this phone show up here.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (!list.isNullOrEmpty()) {
                item("intro") {
                    Note("You deleted these from your backup, and they're still on this phone. Back up now and automatic backup skip them until you choose to back them up here.")
                    Button(onClick = { backUp(list) }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)) { Text("Back up all ${list.size}") }
                }
                items(list, key = { it.localId }) { f ->
                    ListItem(
                        leadingContent = {
                            AsyncImage(PhoneThumbnail(f.uri), contentDescription = null, contentScale = ContentScale.Crop,
                                modifier = Modifier.size(56.dp).clip(RoundedCornerShape(6.dp)))
                        },
                        headlineContent = { Text(f.filename, maxLines = 1) },
                        trailingContent = { TextButton(onClick = { backUp(listOf(f)) }) { Text("Back up") } },
                    )
                }
            }
        }
    }
}
