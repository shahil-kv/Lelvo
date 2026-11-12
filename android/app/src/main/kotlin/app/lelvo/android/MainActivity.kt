package app.lelvo.android

import app.lelvo.android.background.BackupScheduler
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
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import androidx.lifecycle.repeatOnLifecycle
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
import app.lelvo.android.library.FirstBackupScreen
import app.lelvo.android.library.ScanningScreen
import app.lelvo.android.library.LibrarySetup
import app.lelvo.android.library.RecoveryKeyScreen
import app.lelvo.android.settings.LibrariesScreen
import app.lelvo.android.settings.SettingsInfo
import app.lelvo.android.settings.SettingsScreen
import app.lelvo.android.brand.LaunchHost
import app.lelvo.android.collections.AllCollectionsScreen
import app.lelvo.core.index.GalleryFilter
import app.lelvo.android.collections.CollectionPage
import app.lelvo.android.collections.CollectionsScreen
import app.lelvo.android.backup.DuplicatesScreen
import app.lelvo.android.collections.MapPreview
import app.lelvo.core.support.AppLog
import app.lelvo.android.collections.PhotoMapScreen
import app.lelvo.android.collections.MemoriesScreen
import app.lelvo.android.collections.MemoriesSettingsScreen
import app.lelvo.android.collections.MemoryStoryScreen
import app.lelvo.android.collections.RecentlyDeletedScreen
import app.lelvo.android.shell.AppShell
import app.lelvo.android.shell.MessageHost
import app.lelvo.android.shell.Messages
import app.lelvo.android.shell.NavigationBarHeight
import app.lelvo.android.shell.Tab
import app.lelvo.android.backup.BackupScreen
import app.lelvo.android.search.SearchScreen
import app.lelvo.android.library.UnlockScreen
import app.lelvo.android.signin.SignInScreen
import app.lelvo.android.onboarding.IntroScreen
import app.lelvo.android.timeline.TimelineScreen
import app.lelvo.android.ui.theme.LelvoTheme
import app.lelvo.android.viewer.ViewerScreen
import app.lelvo.core.crypto.RecoveryKey
import app.lelvo.core.index.GalleryEntry
import app.lelvo.telegram.AuthStep
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val introPreview = mutableStateOf<Int?>(null)
    private val signInPreview = mutableStateOf<AuthStep?>(null)
    private val libraryPreview = mutableStateOf<String?>(null)
    private val mapPreview = mutableStateOf(false)

    private fun previewStep(name: String): AuthStep? = when (name) {
        "code-telegram" -> AuthStep.WaitCode("We've sent the code to the Telegram app on your other device.", 5, app.lelvo.telegram.CodeDelivery.Telegram, null)
        "code-sms" -> AuthStep.WaitCode("We've sent an SMS with the code to your phone.", 5, app.lelvo.telegram.CodeDelivery.Sms, null)
        "password" -> AuthStep.WaitPassword("hint")
        else -> null
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        handleAction(intent)
        if (BuildConfig.DEBUG) debugMessage(intent)
    }

    /** The launcher shortcuts and the backup notification (iOS's Shortcuts actions open the app the same way). */
    private fun handleAction(intent: android.content.Intent?) {
        val app = application as LelvoApp
        val ready = app.library.isConfigured && app.library.isUnlocked && app.library.setupFinished && !app.demo.active.value
        when (intent?.action) {
            ACTION_BACKUP_NOW -> {
                if (!ready) return
                app.model.tab.value = Tab.Backup
                app.startBackup(includeNew = true)
                Messages.show(Messages.Style.Info, "Backing up new photos")
            }
            ACTION_FREE_UP_SPACE -> if (ready) { app.model.tab.value = Tab.Backup; app.model.openFreeUpSpace.value = true }
            ACTION_OPEN_BACKUP -> if (ready) app.model.tab.value = Tab.Backup
            else -> return
        }
        app.model.actionOpened.tryEmit(Unit)
        // Handled once: a rotation recreates the activity with the same intent.
        intent.action = null
    }

    companion object {
        const val ACTION_BACKUP_NOW = "app.lelvo.android.action.BACKUP_NOW"
        const val ACTION_FREE_UP_SPACE = "app.lelvo.android.action.FREE_UP_SPACE"
        const val ACTION_OPEN_BACKUP = "app.lelvo.android.action.OPEN_BACKUP"
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
        // `--es lelvo.library found|found2|none|error|searching|unlock|recovery|scanning|photos|first` shows that library step with sample data.
        intent.getStringExtra("lelvo.library")?.let { libraryPreview.value = it; return }
        // `--ez lelvo.map true` shows the map with sample places (and the details sheet's small map under it), so it
        // can be checked signed out or on a library without locations. Nothing is read or written.
        if (intent.getBooleanExtra("lelvo.map", false)) { mapPreview.value = true; return }
        // `--ez lelvo.labels true` reads places and things in this phone's photos now and logs a few photos' labels.
        if (intent.getBooleanExtra("lelvo.labels", false)) {
            val app = application as LelvoApp
            lifecycleScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                app.search.index()
                app.photos.assets().take(8).forEach { a -> AppLog.info("Debug: ${a.filename}: ${app.search.things(a.localId)}") }
            }
            return
        }
        // `--ez lelvo.forgetLibrary true` forgets the library on this phone, to run choosing and unlocking for real.
        // `--es lelvo.work backup.overnight|index.refresh|backup.newPhotos`: runs that background work once now (periodic
        // work can't be forced early).
        intent.getStringExtra("lelvo.work")?.let { kind ->
            androidx.work.WorkManager.getInstance(this).enqueue(androidx.work.OneTimeWorkRequestBuilder<app.lelvo.android.background.BackupWorker>()
                .setInputData(androidx.work.Data.Builder().putString(app.lelvo.android.background.BackupWorker.KIND, kind).build()).build())
            return
        }
        // `--el lelvo.trashRetentionSeconds N`: Recently Deleted keeps items N seconds for this run, then the cleanup runs
        // (iOS `-TestTrashRetentionSeconds`). Only on the "Android test" library: the cleanup asks `requireWritable`.
        if (intent.hasExtra("lelvo.trashRetentionSeconds")) {
            val seconds = intent.getLongExtra("lelvo.trashRetentionSeconds", 0)
            if (seconds > 0) {
                app.lelvo.core.index.CloudTrash.retentionMs = seconds * 1000
                app.lelvo.core.support.AppLog.info("Debug: Recently Deleted keeps items $seconds s")
                lifecycleScope.launch(kotlinx.coroutines.Dispatchers.IO) { (application as LelvoApp).sync.emptyExpiredTrash() }
            }
            return
        }
        if (intent.getBooleanExtra("lelvo.forgetLibrary", false)) { (application as LelvoApp).model.forgetLibrary(); return }
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
        if (savedInstanceState == null) handleAction(intent)
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
                if (BuildConfig.DEBUG && mapPreview.value) MapPreview(app) { mapPreview.value = false }
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
        "first" -> FirstBackupScreen(app, onDone = onClose, previewNew = true)
        else -> LibraryScreen(setup, onChosen = onClose, onCreated = { key = it }, onSignOut = onClose)
    }
}

/** The four tabs, with the viewer, Settings and the core check over them. */
@Composable
private fun Library(app: LelvoApp, real: Boolean = false) {
    var open by remember { mutableStateOf<Pair<List<GalleryEntry>, Int>?>(null) }
    var settings by rememberSaveable { mutableStateOf(false) }
    var checking by rememberSaveable { mutableStateOf(false) }
    var libraries by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { app.model.actionOpened.collect { settings = false; libraries = false; checking = false } }
    // Pages opened from Collections, newest last; Back closes the top one.
    var pages by remember { mutableStateOf(emptyList<CollectionPage>()) }
    val openSettings = { settings = true }
    val openPage = { p: CollectionPage -> pages = pages + p }
    val closePage = { pages = pages.dropLast(1) }
    // Search reads where photos were taken while Lelvo is on screen, as iOS does, and again when photos change.
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    val isDemo by app.demo.active.collectAsState()
    LaunchedEffect(lifecycle, isDemo) {
        lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.STARTED) {
            // New backups bring new places to name; a library scan finishing after launch counts too.
            val library = app.store.items().map { it.size }.distinctUntilChanged()
            app.photos.changes().combine(library) { _, _ -> }.conflate().collect { app.search.index(phone = !isDemo) }
        }
    }
    PhoneFavoritePrompt(app)
    Box(Modifier.fillMaxSize()) {
        AppShell(app.model.tab) { tab, modifier ->
            when (tab) {
                Tab.Photos -> TimelineScreen(app.store, app.photos, app.demo, app.prefs, onOpen = { list, index -> open = list to index }, onSettings = openSettings, modifier = modifier)
                Tab.Collections -> CollectionsScreen(app, onOpen = openPage, onSettings = openSettings, modifier = modifier)
                Tab.Search -> SearchScreen(app, onOpen = { list, index -> open = list to index }, onSettings = openSettings, modifier = modifier)
                Tab.Backup -> BackupScreen(app, onSettings = openSettings, modifier = modifier)
            }
        }
        pages.forEachIndexed { i, page ->
            // Each page stays composed under the next, so Back returns to the same scroll position.
            androidx.compose.runtime.key(i, page) {
                Surface(Modifier.fillMaxSize()) {
                    when (page) {
                        is CollectionPage.Grid -> {
                            androidx.activity.compose.BackHandler(enabled = i == pages.lastIndex, onBack = closePage)
                            TimelineScreen(
                                app.store, app.photos, app.demo, app.prefs, onOpen = { list, index -> open = list to index }, onSettings = openSettings,
                                collection = page.filter, onBack = closePage,
                            )
                        }
                        is CollectionPage.All -> AllCollectionsScreen(app, page, onOpen = openPage, onBack = closePage)
                        CollectionPage.RecentlyDeleted -> RecentlyDeletedScreen(app, onBack = closePage)
                        is CollectionPage.MemoryList -> MemoriesScreen(app, page, onOpen = openPage, onBack = closePage)
                        CollectionPage.MemorySettings -> MemoriesSettingsScreen(app.prefs, onBack = closePage)
                        is CollectionPage.Places -> PhotoMapScreen(app, page.entries, onOpen = openPage, onBack = closePage)
                        CollectionPage.Duplicates -> DuplicatesScreen(app, onBack = closePage)
                        is CollectionPage.Story -> MemoryStoryScreen(
                            app, page,
                            onShowAll = { pages = pages.dropLast(1) + CollectionPage.Grid(GalleryFilter.Matching(page.card.title, page.allIds)) },
                            onClose = closePage,
                        )
                    }
                }
            }
        }
        open?.let { (list, index) -> ViewerScreen(list, index, onClose = { open = null }) }
        if (settings) {
            val info by produceState(SettingsInfo("", ""), real, libraries) {
                value = if (!real) SettingsInfo("Demo account", "Demo library") else SettingsInfo(app.accountName(), app.libraryTitle())
            }
            SettingsScreen(
                app, real, info, onClose = { settings = false },
                onSignOut = { settings = false; app.model.reset() },
                // Debug builds only: proves the base against the real library before features are built on it.
                onCoreCheck = if (BuildConfig.DEBUG && real) ({ checking = true }) else null,
                onLibrary = if (real) ({ libraries = true }) else null,
                onBackupRulesChanged = { rules -> BackupScheduler.schedule(app, app.prefs, rulesChanged = rules) },
            )
            if (libraries) LibrariesScreen(app, onClose = { libraries = false })
        }
        if (checking) CoreCheckScreen(app.coreCheck, onClose = { checking = false })
        // One host over everything, so a message shows whichever screen is on top; above the tab bar or the viewer's
        // action row while they show.
        val overTabs = open == null && !settings && !checking && pages.isEmpty()
        MessageHost(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = if (overTabs) NavigationBarHeight else if (open != null) 72.dp else 0.dp))
    }
}

/**
 * A favorite changed on another device reaches this phone's gallery (iOS `PhotosFavoriteSync` sets it in Photos).
 * Android lets an app change a favorite only through the system prompt, so it shows here, once per change, while
 * Lelvo is on screen. Cancelling it isn't asked again until Lelvo starts again.
 */
@Composable
private fun PhoneFavoritePrompt(app: LelvoApp) {
    val requests by app.sync.phoneRequests.collectAsState()
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var showing by remember { mutableStateOf<app.lelvo.data.sync.NoteSync.PhoneFavoriteRequest?>(null) }
    val launcher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartIntentSenderForResult(),
    ) { r ->
        val request = showing ?: return@rememberLauncherForActivityResult
        showing = null
        scope.launch { app.sync.phoneRequestFinished(request, changed = r.resultCode == android.app.Activity.RESULT_OK) }
    }
    val context = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(requests, showing) {
        if (showing != null || android.os.Build.VERSION.SDK_INT < 30) return@LaunchedEffect
        val request = requests.firstOrNull() ?: return@LaunchedEffect
        val uris = app.photos.uris(request.localIds)
        if (uris.isEmpty()) { app.sync.phoneRequestFinished(request, changed = false); return@LaunchedEffect }
        showing = request
        val pi = android.provider.MediaStore.createFavoriteRequest(context.contentResolver, uris, request.value)
        launcher.launch(androidx.activity.result.IntentSenderRequest.Builder(pi.intentSender).build())
    }
}
