package app.lelvo.android.debug

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.shell.Messages
import kotlinx.coroutines.launch

/** Debug only: load a large synthetic library to measure grid scroll (iOS `ScrollLibraryLabView`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScrollLibraryLabScreen(app: LelvoApp, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val scope = rememberCoroutineScope()
    val isDemo by app.demo.active.collectAsState()
    var busy by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf<Int?>(null) }
    var note by remember { mutableStateOf<String?>(null) }

    if (confirm != null) {
        val n = confirm!!
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text("Replace the local index with %,d fake items?".format(n)) },
            text = { Text("Your Telegram channel stays as it is. Re-scan afterwards to put the real library back.") },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    busy = true
                    scope.launch {
                        val loaded = ScrollLibrarySeed.load(app.store, n, demoActive = isDemo)
                        note = "Loaded %,d items. Open Photos and scroll. Re-scan when finished.".format(loaded)
                        Messages.show(Messages.Style.Success, "Scroll library loaded", "%,d items".format(loaded))
                        busy = false
                    }
                }, enabled = !busy) { Text("Load %,d items".format(n), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("Cancel") } },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Scroll library") },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
        ) {
            TextButton(onClick = { confirm = 10_000 }, enabled = !busy && isDemo) { Text("Load 10,000 scroll library") }
            TextButton(onClick = { confirm = 40_000 }, enabled = !busy && isDemo) { Text("Load 40,000 scroll library") }
            Text(
                "Only works in the App Review demo library: it wipes the local index, including changes waiting to be sent to Telegram, so it never runs on a real library. Sign out of the demo to leave it.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp),
            )
            note?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 16.dp))
            }
        }
    }
}
