package app.lelvo.android

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.lelvo.android.debug.CoreCheckScreen
import app.lelvo.android.library.LibraryScreen
import app.lelvo.android.library.PhotosStepScreen
import app.lelvo.android.library.ScanningScreen
import app.lelvo.android.library.LibrarySetup
import app.lelvo.android.library.RecoveryKeyScreen
import app.lelvo.android.settings.SettingsInfo
import app.lelvo.android.settings.SettingsScreen
import app.lelvo.android.brand.LaunchHost
import app.lelvo.android.shell.AppShell
import app.lelvo.android.shell.MessageHost
import app.lelvo.android.shell.Messages
import app.lelvo.android.shell.NavigationBarHeight
import app.lelvo.android.shell.Tab
import app.lelvo.android.shell.TabPlaceholder
import app.lelvo.android.library.UnlockScreen
import app.lelvo.android.signin.SignInScreen
import app.lelvo.android.onboarding.IntroScreen
import app.lelvo.android.timeline.TimelineScreen
import app.lelvo.android.ui.theme.LelvoTheme
import app.lelvo.android.viewer.ViewerScreen
import app.lelvo.core.crypto.RecoveryKey
import app.lelvo.core.index.LibraryItem
import app.lelvo.telegram.AuthStep
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val introPreview = mutableStateOf<Int?>(null)
    private val signInPreview = mutableStateOf<AuthStep?>(null)
    private val libraryPreview = mutableStateOf<String?>(null)

    private fun previewStep(name: String): AuthStep? = when (name) {
        "code-telegram" -> AuthStep.WaitCode("We've sent the code to the Telegram app on your other device.", 5, app.lelvo.telegram.CodeDelivery.Telegram, null)
        "code-sms" -> AuthStep.WaitCode("We've sent an SMS with the code to your phone.", 5, app.lelvo.telegram.CodeDelivery.Sms, null)
        "password" -> AuthStep.WaitPassword("hint")
        else -> null
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        if (BuildConfig.DEBUG) debugMessage(intent)
    }

    /**
     * Debug builds only: shows a message on demand, so snackbars can be checked without a real action.
     * `adb shell am start -n app.lelvo.android/.MainActivity --es lelvo.message "Title" [--es lelvo.style progress|success|failure|info] [--ez lelvo.undo true]`
     */
    private fun debugMessage(intent: android.content.Intent) {
        // `--ei lelvo.intro N` opens the intro on page N over a signed-in app, so it can be checked without signing out.
        if (intent.hasExtra("lelvo.intro")) { introPreview.value = intent.getIntExtra("lelvo.intro", 0); return }
        // `--es lelvo.signin code-telegram|code-sms|password` shows that sign-in step without signing out (nothing is sent).
        intent.getStringExtra("lelvo.signin")?.let { signInPreview.value = previewStep(it); return }
        // `--es lelvo.library found|found2|none|error|searching|unlock|recovery|scanning|photos` shows that library step with sample data.
        intent.getStringExtra("lelvo.library")?.let { libraryPreview.value = it; return }
        val title = intent.getStringExtra("lelvo.message") ?: return
        val style = intent.getStringExtra("lelvo.style")
        if (style == "progress") {
            lifecycleScope.launch {
                Messages.runStoppable {
                    for (i in 0..20) { Messages.progress(title, "$i of 20", i / 20f); kotlinx.coroutines.delay(500) }
                    Messages.show(Messages.Style.Success, "Done")
                }
            }
            return
        }
        val s = Messages.Style.entries.firstOrNull { it.name.equals(style, ignoreCase = true) } ?: Messages.Style.Info
        val undo = if (intent.getBooleanExtra("lelvo.undo", false)) Messages.Action("Undo") { Messages.show(Messages.Style.Info, "Undone") } else null
        Messages.show(s, title, intent.getStringExtra("lelvo.detail"), action = undo)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // The manifest's launch theme draws the launch screen; the app itself uses the plain one.
        setTheme(R.style.Theme_Lelvo)
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as LelvoApp
        if (BuildConfig.DEBUG) debugMessage(intent)
        // Once per process, like iOS: a warm start or a rotation never plays it again.
        val opening = savedInstanceState == null && !app.openingPlayed
        app.openingPlayed = true
        // The opening's first frame is drawn under the system splash, which then goes at once so nothing jumps.
        if (opening && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) splashScreen.setOnExitAnimationListener { it.remove() }
        setContent {
            LelvoTheme { LaunchHost(play = opening) {
                val step by app.telegram.auth.collectAsState()
                val demo by app.demo.active.collectAsState()
                val resetting by app.model.resetting.collectAsState()
                val session by app.model.sessionId.collectAsState()
                // A new session id rebuilds everything below, so nothing of the old account stays in memory.
                key(session) {
                    when {
                        // Sign-in shows at once while the wipe finishes; it waits there until Telegram is ready again.
                        resetting -> SignInScreen(app.telegram, AuthStep.LoggingOut, app.demo)
                        // In the demo nothing talks to Telegram, so its sign-in state doesn't matter.
                        demo -> Library(app)
                        step == AuthStep.Ready -> LibraryFlow(app)
                        else -> SignedOut(app, step)
                    }
                }
                if (BuildConfig.DEBUG) signInPreview.value?.let { st -> key(st) {
                    androidx.activity.compose.BackHandler { signInPreview.value = null }
                    SignInScreen(app.telegram, st, app.demo)
                } }
                if (BuildConfig.DEBUG) libraryPreview.value?.let { k -> key(k) {
                    LibraryPreview(app, k) { libraryPreview.value = null }
                } }
                if (BuildConfig.DEBUG) introPreview.value?.let { p -> key(p) {
                    IntroScreen(app.photos, p, onPage = {}, onFinish = { introPreview.value = null })
                } }
            } }
        }
    }
}

/** Not signed in: the intro first, then sign-in; Back from the phone step returns to the intro page left. */
@Composable
private fun SignedOut(app: LelvoApp, step: AuthStep) {
    var page by rememberSaveable { mutableIntStateOf(0) }
    var intro by rememberSaveable { mutableStateOf(true) }
    val atPhone = step == AuthStep.WaitPhone || step == AuthStep.NeedsCredentials
    if (intro && atPhone) IntroScreen(app.photos, page, onPage = { page = it }, onFinish = { intro = false })
    else SignInScreen(app.telegram, step, app.demo, onIntro = { intro = true })
}

/** Signed in: choose or create the library, unlock it or save the new one's recovery key, then the app. */
@Composable
private fun LibraryFlow(app: LelvoApp) {
    var changes by remember { mutableIntStateOf(0) }
    val setup = app.model.librarySetup
    val recovery by app.model.pendingRecoveryKey
    val signOut: () -> Unit = { app.model.reset() }
    changes.let {
        val key = recovery
        when {
            key != null -> RecoveryKeyScreen(key) { app.model.pendingRecoveryKey.value = null; changes++ }
            !app.library.isConfigured -> LibraryScreen(
                setup, onChosen = { changes++ }, onSignOut = signOut,
                onCreated = { app.model.pendingRecoveryKey.value = it; changes++ },
            )
            !app.library.isUnlocked -> UnlockScreen(setup, onUnlocked = { changes++ }, onBack = {
                app.library.forget(); setup.passphrase = ""; setup.error = null; changes++
            })
            !app.library.setupFinished && !setup.scanDone -> ScanningScreen(setup)
            !app.library.setupFinished -> PhotosStepScreen(setup, app.photos, onFinish = { app.library.setupFinished = true; changes++ })
            else -> Library(app, real = true)
        }
    }
}

/** Debug preview of a library step with sample data: nothing is read from or written to Telegram. */
@Composable
private fun LibraryPreview(app: LelvoApp, kind: String, onClose: () -> Unit) {
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val setup = remember { LibrarySetup.preview(kind, scope) }
    var key by remember { mutableStateOf<RecoveryKey?>(if (kind == "recovery") RecoveryKey.random() else null) }
    androidx.activity.compose.BackHandler(onBack = onClose)
    key?.let { RecoveryKeyScreen(it) { key = null; onClose() }; return }
    when (kind) {
        "unlock" -> UnlockScreen(setup, onUnlocked = onClose, onBack = onClose)
        "scanning" -> if (setup.scanDone) PhotosStepScreen(setup, app.photos, onFinish = onClose) else ScanningScreen(setup)
        "photos" -> PhotosStepScreen(setup, app.photos, onFinish = onClose)
        else -> LibraryScreen(setup, onChosen = onClose, onCreated = { key = it }, onSignOut = onClose)
    }
}

/** The four tabs, with the viewer, Settings and the core check over them. */
@Composable
private fun Library(app: LelvoApp, real: Boolean = false) {
    var open by remember { mutableStateOf<Pair<List<LibraryItem>, Int>?>(null) }
    var settings by rememberSaveable { mutableStateOf(false) }
    var checking by rememberSaveable { mutableStateOf(false) }
    val openSettings = { settings = true }
    Box(Modifier.fillMaxSize()) {
        AppShell(app.model.tab) { tab, modifier ->
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
                onSignOut = { settings = false; app.model.reset() },
                // Debug builds only: proves the base against the real library before features are built on it.
                onCoreCheck = if (BuildConfig.DEBUG && real) ({ checking = true }) else null,
            )
        }
        if (checking) CoreCheckScreen(app.coreCheck, onClose = { checking = false })
        // One host over everything, so a message shows whichever screen is on top; above the tab bar while it shows.
        val overTabs = open == null && !settings && !checking
        MessageHost(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = if (overTabs) NavigationBarHeight else 0.dp))
    }
}
