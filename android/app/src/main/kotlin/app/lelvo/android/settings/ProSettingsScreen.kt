package app.lelvo.android.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.BuildConfig
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.ui.ProBadge

/** Lelvo Pro status. Play Billing products land when the store listing is ready; Debug can unlock for testing. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProSettingsScreen(app: LelvoApp, onBack: () -> Unit) {
    val isPro by app.pro.isPro.collectAsState()
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Lelvo Pro")
                        ProBadge()
                    }
                },
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
            FeatureLine(R.drawable.ic_lock, "Locked folder", "Hide photos behind your phone lock")
            FeatureLine(R.drawable.ic_search, "Smart search", "Find by what’s in a photo — text, things and scenes")
            FeatureLine(R.drawable.ic_auto_awesome, "Smart cleanup", "Similar shots, screenshots, large videos and more")
            FeatureLine(R.drawable.ic_auto_awesome, "Memories themes", "Pets, beaches, food and other theme stories")
            FeatureLine(R.drawable.ic_folder, "Folder backup", "Keep a second copy on a drive you own")
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
                    modifier = Modifier.padding(top = 16.dp),
                )
            }
        }
    }
}

@Composable
private fun FeatureLine(icon: Int, title: String, subtitle: String) {
    Row(
        Modifier.padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(painterResource(icon), null, tint = MaterialTheme.colorScheme.primary)
        Column {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, style = MaterialTheme.typography.titleSmall)
                ProBadge()
            }
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
