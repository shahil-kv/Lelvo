package app.lelvo.android.backup

import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R

/** Keep a second copy in a folder (the Mac's `MacSecondCopyView`): a USB drive, an SD card or a NAS. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SecondCopyScreen(app: LelvoApp, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val service = app.secondCopy
    val s by service.state.collectAsState()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) { service.choose(uri); service.syncNow() }
    }
    Scaffold(modifier, topBar = {
        TopAppBar(title = { Text("Second copy") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            Note("Keep a second copy of your whole library in a folder you choose, such as a USB drive, an SD card or a network drive. Files go into Year/Month folders as they are, decrypted. Nothing is ever deleted from the folder.")
            val name = s.folderName
            if (name == null) {
                Button(onClick = { pick.launch(null) }, modifier = Modifier.fillMaxWidth().padding(16.dp)) { Text("Choose a folder") }
            } else {
                ValueRow("Folder", name)
                ValueRow("Files in the folder", "%,d".format(s.inFolder))
                if (s.bytesLeft > 0) ValueRow("Still to copy", Formatter.formatShortFileSize(context, s.bytesLeft))
                if (s.removedFromLibrary > 0) ValueRow("No longer in your library (kept)", "%,d".format(s.removedFromLibrary))
                s.lastRunAt?.let { ValueRow("Last copied", DateUtils.getRelativeTimeSpanString(it).toString()) }
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (s.running) {
                        if (s.total > 0) {
                            LinearProgressIndicator(progress = { s.done.toFloat() / s.total }, modifier = Modifier.fillMaxWidth())
                            Text("Copying ${minOf(s.done + 1, s.total)} of ${s.total}…", style = MaterialTheme.typography.bodySmall)
                        } else LinearProgressIndicator(Modifier.fillMaxWidth())
                        OutlinedButton(onClick = { service.cancel() }, modifier = Modifier.fillMaxWidth()) { Text("Stop") }
                    } else {
                        Button(onClick = { service.syncNow() }, modifier = Modifier.fillMaxWidth()) { Text("Copy now") }
                        OutlinedButton(onClick = { pick.launch(null) }, modifier = Modifier.fillMaxWidth()) { Text("Choose another folder") }
                        TextButton(onClick = { service.turnOff() }, modifier = Modifier.fillMaxWidth()) {
                            Text("Turn off second copy", color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
                s.message?.let { Note(it) }
                Note("Turning it off keeps the files in the folder. Keep Lelvo open while it copies.")
            }
        }
    }
}
