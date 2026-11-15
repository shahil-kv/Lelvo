package app.lelvo.android.collections

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.timeline.TimelineScreen
import app.lelvo.core.index.GalleryFilter

/**
 * Locked folder: Pro gate, then device lock (PIN / pattern / biometrics via the system sheet), then the timeline
 * with only locked ids (iOS `LockedFolderGate`). Uses KeyguardManager so we don't add a new dependency.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LockedFolderScreen(app: LelvoApp, onBack: () -> Unit, onOpenPro: () -> Unit) {
    val isPro by app.pro.isPro.collectAsState()
    val unlocked by app.lockedFolder.unlockedThisSession.collectAsState()
    val ids by app.lockedFolder.ids.collectAsState()
    var error by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val unlock = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            app.lockedFolder.markSessionUnlocked()
            error = null
        }
    }

    if (!isPro) {
        Scaffold(topBar = {
            TopAppBar(title = { Text("Locked") }, navigationIcon = {
                IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") }
            })
        }) { pad ->
            Column(
                Modifier.fillMaxSize().padding(pad).padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("Locked folder", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Hide photos behind your phone lock. Included with Lelvo Pro.",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
                )
                Button(onClick = onOpenPro) { Text("See Lelvo Pro") }
            }
        }
        return
    }

    if (!unlocked) {
        Scaffold(topBar = {
            TopAppBar(title = { Text("Locked") }, navigationIcon = {
                IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") }
            })
        }) { pad ->
            Column(
                Modifier.fillMaxSize().padding(pad).padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("Locked folder", style = MaterialTheme.typography.titleLarge)
                Text(
                    if (ids.isEmpty()) "Nothing here yet. Select photos and move them to Locked folder."
                    else "${ids.size} hidden. Unlock to see them.",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
                )
                if (ids.isNotEmpty()) {
                    Button(onClick = {
                        error = null
                        val intent = confirmLockIntent(context)
                        if (intent == null) {
                            error = "Set a screen lock in Android Settings to use Locked folder."
                        } else {
                            unlock.launch(intent)
                        }
                    }) { Text("Unlock") }
                }
                error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp))
                }
            }
        }
        return
    }

    TimelineScreen(
        store = app.store, photos = app.photos, demo = app.demo, prefs = app.prefs,
        onOpen = { list, index -> /* viewer opened by parent if wired */ },
        onSettings = {},
        collection = GalleryFilter.Locked, onBack = onBack,
    )
}

@Suppress("DEPRECATION")
private fun confirmLockIntent(context: Context): Intent? {
    val km = context.getSystemService(KeyguardManager::class.java) ?: return null
    if (!km.isDeviceSecure) return null
    return km.createConfirmDeviceCredentialIntent("Unlock Locked folder", null)
}
