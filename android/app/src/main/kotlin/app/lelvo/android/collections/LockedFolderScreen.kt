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
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.timeline.TimelineScreen
import app.lelvo.core.index.GalleryFilter

/**
 * Locked folder: Pro gate, Google Photos–style setup, device lock, then the timeline with only locked ids.
 * Uses KeyguardManager so we don't add a new dependency (iOS `LockedFolderGate`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LockedFolderScreen(app: LelvoApp, onBack: () -> Unit, onOpenPro: () -> Unit) {
    val isPro by app.pro.isPro.collectAsState()
    val unlocked by app.lockedFolder.unlockedThisSession.collectAsState()
    val setUp by app.lockedFolder.isSetUp.collectAsState()
    val synced by app.lockedFolder.syncedLockedIds.collectAsState()
    val pending by app.lockedFolder.pendingLocalIds.collectAsState()
    val hiddenCount = synced.size + pending.size
    var error by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val unlock = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            app.lockedFolder.markSetUp()
            app.lockedFolder.markSessionUnlocked()
            error = null
        }
    }

    // Google Photos: leaving Locked Folder re-locks.
    DisposableEffect(Unit) {
        onDispose { app.lockedFolder.lockSession() }
    }

    // Second device: pull MetaLog lock notes so iPhone/Mac membership shows here.
    LaunchedEffect(isPro) {
        if (isPro) {
            app.lockedFolder.syncFromChannel(app.scanner, app.sync, app.store)
        }
    }

    // Ente/Immich: block screenshots and blank the app-switcher thumbnail while unlocked.
    val view = LocalView.current
    DisposableEffect(unlocked) {
        val window = view.context.findActivityWindow()
        if (unlocked && window != null) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    if (!isPro) {
        GateScaffold(onBack) {
            Text("Locked folder", style = MaterialTheme.typography.titleLarge)
            Text(
                "Hide photos behind your phone lock. Included with Lelvo Pro.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
            )
            Button(onClick = onOpenPro) { Text("See Lelvo Pro") }
        }
        return
    }

    if (!setUp) {
        GateScaffold(onBack) {
            Text("Locked folder", style = MaterialTheme.typography.titleLarge)
            Text(
                "Photos you move here stay hidden in Lelvo on every device signed into this library. Unlock with your phone lock. Your Telegram library still holds the files.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
            )
            Button(onClick = {
                error = null
                val intent = confirmLockIntent(context, "Set up Locked folder")
                if (intent == null) {
                    error = "Set a screen lock in Android Settings to use Locked folder."
                } else {
                    unlock.launch(intent)
                }
            }) { Text("Set up Locked Folder") }
            error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp))
            }
        }
        return
    }

    if (!unlocked) {
        GateScaffold(onBack) {
            Text("Locked folder", style = MaterialTheme.typography.titleLarge)
            Text(
                if (hiddenCount == 0) "Nothing here yet. Unlock to add photos, or select photos in your library and move them here."
                else "Unlock to see your hidden photos.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
            )
            Button(onClick = {
                error = null
                val intent = confirmLockIntent(context, "Unlock Locked folder")
                if (intent == null) {
                    error = "Set a screen lock in Android Settings to use Locked folder."
                } else {
                    unlock.launch(intent)
                }
            }) { Text("Unlock") }
            error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp))
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GateScaffold(onBack: () -> Unit, content: @Composable () -> Unit) {
    Scaffold(topBar = {
        TopAppBar(
            title = {
                androidx.compose.foundation.layout.Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("Locked")
                    app.lelvo.android.ui.ProBadge()
                }
            },
            navigationIcon = {
                IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") }
            },
        )
    }) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).padding(24.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) { content() }
    }
}

@Suppress("DEPRECATION")
internal fun confirmLockIntent(context: Context, title: String): Intent? {
    val km = context.getSystemService(KeyguardManager::class.java) ?: return null
    if (!km.isDeviceSecure) return null
    return km.createConfirmDeviceCredentialIntent(title, null)
}

private fun Context.findActivityWindow(): android.view.Window? {
    var ctx: Context? = this
    while (ctx is android.content.ContextWrapper) {
        if (ctx is android.app.Activity) return ctx.window
        ctx = ctx.baseContext
    }
    return null
}
