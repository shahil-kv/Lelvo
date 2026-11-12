package app.lelvo.android.backup

import android.os.StatFs
import android.text.format.Formatter
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.shell.Messages
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Save everything to the phone (iOS `SaveAllToPhotosView`): every item only in the Telegram library goes back to this
 * phone's photos with its date, one at a time, linked to its backup. Nothing is removed from Telegram.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SaveAllScreen(app: LelvoApp, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<LibraryItem>?>(null) }
    var free by remember { mutableStateOf(Long.MAX_VALUE) }
    var job by remember { mutableStateOf<Job?>(null) }
    var done by remember { mutableIntStateOf(0) }
    var failures by remember { mutableStateOf<List<String>>(emptyList()) }
    var confirm by remember { mutableStateOf(false) }
    var reload by remember { mutableIntStateOf(0) }

    LaunchedEffect(reload) {
        items = withContext(Dispatchers.IO) {
            val all = app.store.items(ItemStatus.BackedUp).filter { it.parts["o"]?.isNotEmpty() == true }
            // On this phone already: its own photo, or a copy linked to it.
            val aliases = app.store.aliases()
            val onPhone = app.backup.phone.files(all.mapNotNull { it.localId } + aliases.keys).keys
            val aliased = aliases.filterKeys { it in onPhone }.values.toSet()
            free = runCatching { StatFs(context.filesDir.path).availableBytes }.getOrDefault(Long.MAX_VALUE)
            all.filter { it.id !in aliased && it.localId?.let(onPhone::contains) != true }.sortedByDescending { it.createdAt ?: 0 }
        }
    }
    val list = items.orEmpty()
    val needed = list.sumOf { it.fileSize }
    val running = job != null
    // Android may stop work soon after the screen locks; the screen staying on keeps it going, as on iOS.
    if (running) DisposableEffect(Unit) {
        val window = (context as? android.app.Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }

    fun run() {
        job = scope.launch {
            done = 0
            failures = emptyList()
            var saved = 0
            val started = System.currentTimeMillis()
            AppLog.info("Save all to the phone: ${list.size} items, ${needed shr 20} MB")
            try {
                for (item in list) {
                    try {
                        app.saver.save(item) {}
                        saved++
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failures = failures + "${item.filename}: ${e.message ?: "Couldn't save"}"
                    }
                    done++
                }
            } finally {
                val stopped = done < list.size
                AppLog.info("Save all to the phone finished: $saved saved, ${failures.size} failed${if (stopped) ", stopped" else ""} in ${(System.currentTimeMillis() - started) / 1000} s")
                Messages.show(
                    if (failures.isEmpty()) Messages.Style.Success else Messages.Style.Failure,
                    if (stopped) "Stopped" else "Saved $saved to this phone",
                    if (failures.isEmpty()) "They're in your photos, linked to your backup." else "${failures.size} couldn't be saved; see the list. Tap Save again to retry them.",
                )
                job = null
                reload++
            }
        }
    }

    Scaffold(modifier, topBar = {
        TopAppBar(title = { Text("Save all to this phone") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } })
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            item("intro") {
                Note("Save every photo and video that's only in your Telegram library back to this phone, with their dates. Nothing is removed from Telegram.")
                ValueRow("Only in your Telegram library", items?.size?.let { "%,d".format(it) } ?: "…")
                ValueRow("Space needed", Formatter.formatShortFileSize(context, needed))
                if (needed > free) Note("Not enough space: free up ${Formatter.formatShortFileSize(context, needed - free)} more first, or save a few at a time from the grid.")
            }
            item("actions") {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (running) {
                        LinearProgressIndicator(progress = { done.toFloat() / maxOf(1, list.size) }, modifier = Modifier.fillMaxWidth())
                        Text("Saving ${minOf(done + 1, list.size)} of ${list.size}…", style = MaterialTheme.typography.bodySmall)
                        OutlinedButton(onClick = { job?.cancel() }, modifier = Modifier.fillMaxWidth()) { Text("Stop") }
                    } else {
                        Button(onClick = { confirm = true }, enabled = list.isNotEmpty() && needed <= free, modifier = Modifier.fillMaxWidth()) {
                            Text("Save ${"%,d".format(list.size)} to this phone")
                        }
                    }
                }
                Note("Keep Lelvo open while it saves. If it stops, tap again: what's already saved is skipped.")
            }
            if (failures.isNotEmpty()) {
                item("failedHeader") { Header("Couldn't save") }
                items(failures) { ListItem(headlineContent = { Text(it, color = MaterialTheme.colorScheme.error) }) }
            }
        }
    }
    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text("Save ${"%,d".format(list.size)} items to this phone?") },
        text = { Text("They download from your Telegram library, ${Formatter.formatShortFileSize(context, needed)} in all.") },
        confirmButton = { TextButton(onClick = { confirm = false; run() }) { Text("Save") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
    )
}
