package app.lelvo.android

import androidx.compose.runtime.mutableStateOf
import app.lelvo.android.library.LibrarySetup
import app.lelvo.android.shell.Tab
import app.lelvo.core.crypto.RecoveryKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import app.lelvo.core.support.AppLog
import app.lelvo.telegram.AuthStep

/**
 * UI-wide state, like iOS `AppModel`: the selected tab (so shortcuts can open one later) and signing out. One per
 * process, held by [LelvoApp].
 */
class AppModel(private val app: LelvoApp) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val tab = MutableStateFlow(Tab.Photos)

    private val _sessionId = MutableStateFlow(0)
    /** Bumped by [reset] so the signed-in screens are rebuilt with nothing of the old account in memory. */
    val sessionId: StateFlow<Int> = _sessionId

    private val _resetting = MutableStateFlow(false)
    /** True while a reset wipes; sign-in shows at once instead of waiting for Telegram to answer. */
    val resetting: StateFlow<Boolean> = _resetting

    private var resetJob: Job? = null

    /**
     * The library step's state. Kept here, not in a screen, so turning the phone neither loses the typed passphrase
     * nor cancels a library half-way through being created. A reset starts it afresh.
     */
    var librarySetup = LibrarySetup(app.library, scope, app.scanner, relink = { app.linker.relink() })
        private set

    /** A new library's recovery key until the user says it's saved. Memory only, never written anywhere. */
    val pendingRecoveryKey = mutableStateOf<RecoveryKey?>(null)

    init {
        // Without a session nothing can reach the library, so this works like Sign out and reset. The channel and the
        // photos on this phone aren't touched; signing in again brings the library back.
        scope.launch {
            app.telegram.sessionEndedElsewhere.collect {
                if (!app.demo.active.value) reset(keepingChoices = true)
            }
        }
        catchUpWhenReady()
        // Telegram asks for a phone number while a library is still set up here: the session went without the reset
        // that signing out does, and without TDLib reporting it as ended (seen on the emulator, 2026-11-11). Wipe as
        // if it had ended elsewhere, so signing in asks for the library and its passphrase again and nothing of the
        // old account stays for the next one. The channel isn't touched; the passphrase brings the library back.
        scope.launch {
            app.telegram.auth.collect { step ->
                if (step == AuthStep.WaitPhone && app.library.chatId != null && !_resetting.value && !app.demo.active.value) {
                    AppLog.warn("Signed out of Telegram but a library was still set up; removing it from this phone")
                    reset(keepingChoices = true)
                }
            }
        }
    }

    /**
     * Brings the index up to date each time Telegram is ready with a library open (launch, sign-in, a reconnect): what
     * other devices backed up, deleted or favorited meanwhile. The first scan after choosing a library runs on its own
     * screen instead.
     */
    private fun catchUpWhenReady() = scope.launch {
        app.telegram.auth.collect { step ->
            if (step != AuthStep.Ready || app.demo.active.value) return@collect
            val library = app.library
            if (!library.isConfigured || !library.isUnlocked || !library.setupFinished) return@collect
            runCatching { app.scanner.catchUp(); app.linker.relink() }.onFailure { if (it !is kotlinx.coroutines.CancellationException) AppLog.warn("Library catch-up failed", it) }
        }
    }

    /**
     * Switches to another library (Settings → Library). The passphrase is checked before anything changes; then the
     * index is rebuilt from the new library and linked to this phone's photos. Nothing is deleted from either library.
     */
    suspend fun switchLibrary(chatId: Long, secret: String) {
        app.library.switchTo(app.library.open(chatId, secret))
    }

    /** Reads the whole library again (Settings → Library → Re-scan), then links what it found to this phone's photos. */
    suspend fun rescan(): app.lelvo.data.LibraryScanner.Summary = app.scanner.fullScan().also { app.linker.relink() }

    /**
     * A library just created from Settings: it's in use and empty, so there's nothing to restore. The recovery key
     * shows next, over the app.
     */
    fun createdLibrary(key: RecoveryKey) {
        app.library.setupFinished = true
        pendingRecoveryKey.value = key
        scope.launch { runCatching { app.scanner.fullScan() } }
    }

    /**
     * Forgets the chosen library on this phone (its keys and the index too) and goes back to choosing one. The
     * channel isn't touched. Debug builds reach it with `--ez lelvo.forgetLibrary true`; Settings gets it in Phase C.
     */
    fun forgetLibrary() {
        scope.launch {
            withContext(Dispatchers.IO) { app.store.deleteAll(); app.library.forget() }
            librarySetup = LibrarySetup(app.library, scope, app.scanner, relink = { app.linker.relink() })
            pendingRecoveryKey.value = null
            _sessionId.value++
        }
    }

    /**
     * Shows sign-in at once, then wipes in the background (iOS #70: waiting for the wipe first left Settings on screen
     * for seconds, because signing out waits for Telegram). Resets run one after another, never at the same time.
     */
    fun reset(keepingChoices: Boolean = false) {
        tab.value = Tab.Photos
        librarySetup = LibrarySetup(app.library, scope, app.scanner, relink = { app.linker.relink() })
        pendingRecoveryKey.value = null
        _sessionId.value++
        _resetting.value = true
        val previous = resetJob
        lateinit var job: Job
        job = scope.launch(start = CoroutineStart.LAZY) {
            previous?.join()
            // Only the last reset asked for clears the flag; an earlier one finishing mustn't.
            try { app.resetEverything(keepingChoices) } finally { if (resetJob === job) _resetting.value = false }
        }
        resetJob = job
        job.start()
    }

    /** Returns once a running reset has finished. Sign-in waits for this so it never sees the old session. */
    suspend fun waitForReset() { resetJob?.join() }
}
