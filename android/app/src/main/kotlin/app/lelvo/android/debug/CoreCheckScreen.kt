package app.lelvo.android.debug

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.data.CoreCheck
import kotlinx.coroutines.launch

/** Debug only: runs [CoreCheck] on the real library and shows each result. Read-only on Telegram. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CoreCheckScreen(check: CoreCheck, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val results by check.results.collectAsState()
    val running by check.running.collectAsState()
    val scope = rememberCoroutineScope()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Core check") },
                navigationIcon = { IconButton(onClick = onClose) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                "Reads your library to prove Android opens it like the iPhone: keys, a full scan, thumbnails, originals and " +
                    "a ranged read. Nothing is sent or deleted. It downloads a few files, so use Wi-Fi.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = { scope.launch { check.run() } }, enabled = !running, modifier = Modifier.fillMaxWidth()) {
                Text(if (running) "Checking…" else if (results.isEmpty()) "Run the check" else "Run again")
            }
            for (r in results) {
                ListItem(
                    headlineContent = { Text(r.name) },
                    supportingContent = { Text(r.detail) },
                    leadingContent = {
                        when (r.ok) {
                            true -> Text("✓", color = Lelvo.colors.green, style = MaterialTheme.typography.titleLarge)
                            false -> Text("✕", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.titleLarge)
                            null -> if (running && r == results.last()) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                            else Text("–", style = MaterialTheme.typography.titleLarge)
                        }
                    },
                )
            }
        }
    }
}
