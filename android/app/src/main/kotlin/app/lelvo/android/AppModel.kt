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
    var librarySetup = LibrarySetup(app.library, scope, app.scanner)
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
    }

    /**
     * Shows sign-in at once, then wipes in the background (iOS #70: waiting for the wipe first left Settings on screen
     * for seconds, because signing out waits for Telegram). Resets run one after another, never at the same time.
     */
    fun reset(keepingChoices: Boolean = false) {
        tab.value = Tab.Photos
        librarySetup = LibrarySetup(app.library, scope, app.scanner)
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
