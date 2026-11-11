package app.lelvo.telegram

import android.util.Log
import app.lelvo.core.session.SessionWatch
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.drinkless.tdlib.Client
import org.drinkless.tdlib.TdApi
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Read from the database key store: a store that fails to answer is not the same as a key that was never made.
 * iOS learned this the hard way: an older build made a new key after a failed read and lost the session.
 */
sealed interface StoredKey {
    data class Found(val key: ByteArray) : StoredKey
    data object Missing : StoredKey
    data object Failed : StoredKey
}

interface DatabaseKeyStore {
    fun read(): StoredKey
    fun write(key: ByteArray)
}

data class TelegramConfig(
    val apiId: Int,
    val apiHash: String,
    val useTestDc: Boolean,
    val dataDir: File,
    val cacheDir: File,
    val deviceModel: String,
    val appVersion: String,
    val languageCode: String,
)

/**
 * One TDLib client for the process: sign-in, requests as suspend calls, updates as a flow. The Android counterpart
 * of the sign-in half of iOS `TDService`.
 */
class TdClient(private val config: TelegramConfig?, private val keys: DatabaseKeyStore) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private var client: Client? = null
    private val closedClients = HashSet<Client>()
    private val sessionWatch = SessionWatch()
    private var startingOver = false

    private val _auth = MutableStateFlow<AuthStep>(if (config == null) AuthStep.NeedsCredentials else AuthStep.Starting)
    val auth: StateFlow<AuthStep> = _auth

    private val _updates = MutableSharedFlow<TdApi.Object>(extraBufferCapacity = 256)
    val updates: SharedFlow<TdApi.Object> = _updates

    /** Emits once each time the session was ended outside this app (Telegram → Devices, or by Telegram). */
    private val _sessionEndedElsewhere = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val sessionEndedElsewhere: SharedFlow<Unit> = _sessionEndedElsewhere

    // Separate folders for the test servers: their sessions and files must never mix with the real ones.
    private val databaseDir get() = File(config!!.dataDir, if (config.useTestDc) "tdlib-test" else "tdlib")
    private val filesDir get() = File(config!!.cacheDir, if (config.useTestDc) "tdlib-files-test" else "tdlib-files")

    fun start() {
        if (config == null) { _auth.value = AuthStep.NeedsCredentials; return }
        databaseDir.mkdirs(); filesDir.mkdirs()
        // Errors only: TDLib's own log can contain phone numbers and message text.
        Client.execute(TdApi.SetLogVerbosityLevel(1))
        synchronized(lock) {
            if (client != null) return
            lateinit var created: Client
            created = Client.create({ obj -> handle(obj, created) }, { e -> Log.w(TAG, "update handler failed", e) }, null)
            client = created
        }
    }

    suspend fun <T : TdApi.Object> send(function: TdApi.Function<T>): T {
        val c = synchronized(lock) { client } ?: throw TelegramException(0, "Telegram isn't running")
        return suspendCancellableCoroutine { cont ->
            c.send(function) { result ->
                if (result is TdApi.Error) cont.resumeWithException(TelegramException(result.code, result.message))
                else @Suppress("UNCHECKED_CAST") cont.resume(result as T)
            }
        }
    }

    // MARK: Sign-in

    suspend fun submitPhone(phone: String) { send(TdApi.SetAuthenticationPhoneNumber(phone, null)) }
    suspend fun submitCode(code: String) { send(TdApi.CheckAuthenticationCode(code)) }

    /** Asks Telegram for the code the other way it offered; the new state arrives as a fresh [AuthStep.WaitCode]. */
    suspend fun resendCode() { send(TdApi.ResendAuthenticationCode(TdApi.ResendCodeReasonUserRequest())) }
    suspend fun submitPassword(password: String) { send(TdApi.CheckAuthenticationPassword(password)) }

    suspend fun logOut() {
        synchronized(lock) { sessionWatch.ownSignOut() }
        runCatching { send(TdApi.LogOut()) }
    }

    /** Signs out and starts a fresh login, like "Use a different Telegram account" on iOS. */
    suspend fun switchAccount() {
        val old = synchronized(lock) { client }
        logOut()
        waitUntilClosed(old)
        synchronized(lock) { if (client === old) client = null }
        start()
    }

    // MARK: Updates

    private fun isCurrent(c: Client) = synchronized(lock) { client === c }

    private fun handle(obj: TdApi.Object, from: Client) {
        if (obj is TdApi.UpdateAuthorizationState) {
            if (obj.authorizationState is TdApi.AuthorizationStateClosed) synchronized(lock) { closedClients.add(from) }
            // A client being replaced (sign out, other account) must not drive the sign-in screens or clear the new one.
            if (!isCurrent(from)) return
            handleAuth(obj.authorizationState, from)
        }
        _updates.tryEmit(obj)
    }

    private fun handleAuth(state: TdApi.AuthorizationState, from: Client) {
        when (state) {
            is TdApi.AuthorizationStateWaitTdlibParameters -> scope.launch { setParameters(from) }
            is TdApi.AuthorizationStateWaitPhoneNumber -> _auth.value = AuthStep.WaitPhone
            is TdApi.AuthorizationStateWaitCode -> _auth.value = AuthStep.WaitCode(
                CodeInfo.describe(state.codeInfo), CodeInfo.length(state.codeInfo.type),
                CodeInfo.delivery(state.codeInfo.type), CodeInfo.resend(state.codeInfo),
            )
            is TdApi.AuthorizationStateWaitPassword -> _auth.value = AuthStep.WaitPassword(state.passwordHint.orEmpty())
            is TdApi.AuthorizationStateWaitEmailAddress, is TdApi.AuthorizationStateWaitEmailCode -> _auth.value = AuthStep.WaitEmail
            is TdApi.AuthorizationStateWaitOtherDeviceConfirmation -> _auth.value = AuthStep.WaitOtherDevice(state.link)
            is TdApi.AuthorizationStateWaitRegistration, is TdApi.AuthorizationStateWaitPremiumPurchase ->
                _auth.value = AuthStep.WaitRegistration
            is TdApi.AuthorizationStateReady -> {
                synchronized(lock) { sessionWatch.ready() }
                _auth.value = AuthStep.Ready
                Log.i(TAG, "Telegram session ready")
            }
            is TdApi.AuthorizationStateLoggingOut -> {
                synchronized(lock) { sessionWatch.loggingOut() }
                _auth.value = AuthStep.LoggingOut
            }
            is TdApi.AuthorizationStateClosing -> _auth.value = AuthStep.LoggingOut
            is TdApi.AuthorizationStateClosed -> {
                val endedElsewhere = synchronized(lock) {
                    if (client === from) client = null
                    sessionWatch.closed()
                }
                _auth.value = AuthStep.Closed
                if (endedElsewhere) {
                    Log.i(TAG, "The Telegram session was ended outside this app")
                    _sessionEndedElsewhere.tryEmit(Unit)
                }
                // TDLib can't sign in again on a closed instance; start a fresh one so the phone step shows.
                if (!startingOver) start()
            }
        }
    }

    private suspend fun setParameters(from: Client) {
        val cfg = config ?: return
        // A key store that doesn't answer usually does a moment later; until then, wait rather than guess.
        var key: ByteArray? = null
        for (attempt in 0 until 40) {
            when (val read = keys.read()) {
                is StoredKey.Found -> if (read.key.size == 32) { key = read.key; break } else {
                    key = newKey(); break
                }
                StoredKey.Missing -> { key = newKey(); break }
                StoredKey.Failed -> delay(500)
            }
        }
        if (key == null) {
            Log.e(TAG, "Couldn't read Telegram's database key; not starting Telegram")
            return
        }
        val p = TdApi.SetTdlibParameters().apply {
            useTestDc = cfg.useTestDc
            databaseDirectory = databaseDir.path
            filesDirectory = filesDir.path
            databaseEncryptionKey = key
            useFileDatabase = true
            useChatInfoDatabase = true
            // No message database: interrupted sends are reconciled from history instead of auto-resent (as on iOS).
            useMessageDatabase = false
            useSecretChats = false
            apiId = cfg.apiId
            apiHash = cfg.apiHash
            systemLanguageCode = cfg.languageCode
            deviceModel = cfg.deviceModel
            systemVersion = ""
            applicationVersion = cfg.appVersion
        }
        try {
            send(p)
        } catch (e: TelegramException) {
            Log.e(TAG, "setTdlibParameters failed: ${e.message}")
            if (e.message.contains("database encryption key", ignoreCase = true)) startOverAfterLostDatabaseKey(from)
            else if (app.lelvo.core.session.TelegramErrors.keysRejected(e.message)) _auth.value = AuthStep.NeedsCredentials
        }
    }

    private fun newKey(): ByteArray = ByteArray(32).also { java.security.SecureRandom().nextBytes(it); keys.write(it) }

    /**
     * TDLib's database doesn't open with the saved key. The session in it can't be recovered, so start a new database
     * and sign in again, instead of hanging. Only Telegram's session and cache go: the library, its keys and the index stay.
     */
    private suspend fun startOverAfterLostDatabaseKey(failed: Client) {
        synchronized(lock) {
            if (client !== failed || startingOver) return
            startingOver = true
            sessionWatch.ownSignOut()
        }
        Log.w(TAG, "Telegram's data on this device doesn't open with its saved key; starting it again, sign-in needed")
        runCatching { send(TdApi.Close()) }
        waitUntilClosed(failed)
        databaseDir.deleteRecursively(); filesDir.deleteRecursively()
        synchronized(lock) { if (client === failed) client = null; startingOver = false }
        start()
    }

    /** Waits until [old] has fully closed, so a new client never opens the database while the old one still holds it. */
    private suspend fun waitUntilClosed(old: Client?, timeoutMs: Long = 15_000) {
        if (old == null) return
        withTimeoutOrNull(timeoutMs) { while (synchronized(lock) { old !in closedClients }) delay(100) }
        synchronized(lock) { closedClients.remove(old) }
    }

    private companion object { const val TAG = "Lelvo.TDLib" }
}
