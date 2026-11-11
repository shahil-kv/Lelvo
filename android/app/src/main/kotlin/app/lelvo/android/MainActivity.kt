package app.lelvo.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.lelvo.android.debug.CoreCheckScreen
import app.lelvo.android.library.ChooseLibraryScreen
import app.lelvo.android.settings.SettingsInfo
import app.lelvo.android.settings.SettingsScreen
import app.lelvo.android.shell.AppShell
import app.lelvo.android.shell.Tab
import app.lelvo.android.shell.TabPlaceholder
import app.lelvo.android.library.UnlockScreen
import app.lelvo.android.signin.SignInScreen
import app.lelvo.android.timeline.TimelineScreen
import app.lelvo.android.ui.theme.LelvoTheme
import app.lelvo.android.viewer.ViewerScreen
import app.lelvo.core.index.LibraryItem
import app.lelvo.telegram.AuthStep
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as LelvoApp
        setContent {
            LelvoTheme {
                val step by app.telegram.auth.collectAsState()
                val demo by app.demo.active.collectAsState()
                when {
                    // In the demo nothing talks to Telegram, so its sign-in state doesn't matter.
                    demo -> Library(app, onSignOut = { app.demo.exit(); app.prefs.reset() })
                    step == AuthStep.Ready -> LibraryFlow(app)
                    else -> SignInScreen(app.telegram, step, app.demo)
                }
            }
        }
    }
}

/** Signed in: choose the library, unlock it, then the app. */
@Composable
private fun LibraryFlow(app: LelvoApp) {
    val scope = rememberCoroutineScope()
    var changes by remember { mutableIntStateOf(0) }
    val signOut: () -> Unit = { scope.launch { app.library.forget(); app.store.deleteAll(); app.prefs.reset(); app.telegram.logOut() } }
    changes.let {
        when {
            !app.library.isConfigured -> ChooseLibraryScreen(app.library, onChosen = { changes++ }, onSignOut = signOut)
            !app.library.isUnlocked -> UnlockScreen(app.library, onUnlocked = { changes++ }, onOtherLibrary = { app.library.forget(); changes++ })
            else -> Library(app, onSignOut = { signOut() }, real = true)
        }
    }
}

/** The four tabs, with the viewer, Settings and the core check over them. */
@Composable
private fun Library(app: LelvoApp, onSignOut: suspend () -> Unit, real: Boolean = false) {
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf<Pair<List<LibraryItem>, Int>?>(null) }
    var settings by rememberSaveable { mutableStateOf(false) }
    var checking by rememberSaveable { mutableStateOf(false) }
    val openSettings = { settings = true }
    AppShell { tab, modifier ->
        when (tab) {
            Tab.Photos -> TimelineScreen(app.store, app.demo, app.prefs, onOpen = { list, index -> open = list to index }, onSettings = openSettings, modifier = modifier)
            else -> TabPlaceholder(tab, app.demo, openSettings, modifier)
        }
    }
    open?.let { (list, index) -> ViewerScreen(list, index, onClose = { open = null }) }
    if (settings) {
        val info by produceState(SettingsInfo("", "", BuildConfig.VERSION_NAME), real) {
            value = if (!real) SettingsInfo("Demo account", "Demo library", BuildConfig.VERSION_NAME)
            else SettingsInfo(app.accountName(), app.libraryTitle(), BuildConfig.VERSION_NAME)
        }
        SettingsScreen(
            info, onClose = { settings = false },
            onSignOut = { settings = false; scope.launch { onSignOut() } },
            // Debug builds only: proves the base against the real library before features are built on it.
            onCoreCheck = if (BuildConfig.DEBUG && real) ({ checking = true }) else null,
        )
    }
    if (checking) CoreCheckScreen(app.coreCheck, onClose = { checking = false })
}
