package app.lelvo.android.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.BuildConfig
import app.lelvo.android.LelvoApp
import app.lelvo.android.R

/** Lelvo Pro status. Play Billing products land when the store listing is ready; Debug can unlock for testing. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProSettingsScreen(app: LelvoApp, onBack: () -> Unit) {
    val isPro by app.pro.isPro.collectAsState()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Lelvo Pro") },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") }
                },
            )
        },
    ) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(16.dp)) {
            Text(if (isPro) "Pro is on" else "Pro is off", style = MaterialTheme.typography.titleMedium)
            Text(
                "Backup, restore and Free Up Space stay free. Pro adds Locked folder and more.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
            )
            if (BuildConfig.DEBUG) {
                ToggleRow(
                    "Debug: unlock Pro",
                    "For building Pro features before Play Billing is live.",
                    app.pro.debugUnlocked,
                    icon = R.drawable.ic_lock,
                ) { app.pro.debugUnlocked = it }
            } else if (!isPro) {
                Text(
                    "Purchases will use Google Play when Lelvo Pro is listed.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
