package app.lelvo.data

import android.content.Context
import app.lelvo.core.support.AppLog
import app.lelvo.core.crypto.Argon2id
import app.lelvo.core.crypto.E2EKeys
import app.lelvo.core.crypto.RecoveryKey
import app.lelvo.core.format.HeaderResult
import app.lelvo.core.format.LibraryHeader
import app.lelvo.telegram.TdClient
import com.lambdapioneer.argon2kt.Argon2Kt
import com.lambdapioneer.argon2kt.Argon2Mode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.drinkless.tdlib.TdApi

/** What the user reads when a library can't be used. Same sentences as iOS `LibraryError`, plus Android's E2E-only rule. */
class LibraryException(message: String) : Exception(message) {
    companion object {
        val notALibrary = LibraryException("That channel isn't a Lelvo library. Pick another channel or create a new library.")
        val wrongPassphrase = LibraryException("That passphrase or recovery key doesn't open this library.")
        val newerVersion = LibraryException("This library was set up by a newer version of Lelvo. Update Lelvo to open it.")
        val damaged = LibraryException("This library's settings in Telegram can't be read. Open it in Lelvo on iPhone or Mac.")
        val noLibrary = LibraryException("Choose or create your Lelvo library first.")
        val headerNotSaved = LibraryException(
            "Telegram didn't save the change. Check your connection and try again; your library still opens as before.",
        )
        val testOnly = LibraryException(
            "This test version changes only the library named “Android test”. Your other libraries are read, never changed.",
        )
        val notEncrypted = LibraryException(
            "This library isn't end-to-end encrypted. Lelvo for Android opens only encrypted libraries. Open it in Lelvo on iPhone or Mac.",
        )
    }
}

/**
 * The user's library channel: finding it, its header and its keys. The Android counterpart of the choosing and
 * unlocking half of iOS `LibraryService`.
 */
class LibraryService(
    context: Context,
    private val td: TdClient,
    private val secrets: SecretStore,
    /** Until the cross-platform gate (Phase N) passes, writes go only to the "Android test" library (owner, 2026-11-11). */
    private val guardWrites: Boolean = true,
) {
    private val prefs = context.getSharedPreferences("library", Context.MODE_PRIVATE)
    @Volatile private var cachedKeys: E2EKeys? = null

    data class ChannelChoice(val id: Long, val title: String, val isLibrary: Boolean, val encrypted: Boolean)

    val chatId: Long? get() = if (prefs.contains(CHAT_ID)) prefs.getLong(CHAT_ID, 0) else null

    val header: LibraryHeader?
        get() = prefs.getString(HEADER, null)?.let { (LibraryHeader.parse(it) as? HeaderResult.Found)?.header }

    val isConfigured: Boolean get() = chatId != null && header != null

    /** The keys, only when they were stored for this very channel (as iOS ties keys to their library). */
    val keys: E2EKeys?
        get() {
            cachedKeys?.let { return it }
            val chat = chatId ?: return null
            if (!prefs.contains(KEYS_CHAT_ID) || prefs.getLong(KEYS_CHAT_ID, 0) != chat) return null
            val raw = (secrets.read(MASTER_KEY) as? SecretStore.Read.Found)?.value ?: return null
            if (raw.size != 32) return null
            return E2EKeys(raw).also { cachedKeys = it }
        }

    val isUnlocked: Boolean get() = keys != null

    /**
     * Set once the scan and the photos step after choosing or creating this library are done (iOS
     * `onboardingComplete`). Kept with the library, so choosing another one goes through them again.
     */
    var setupFinished: Boolean
        get() = prefs.getBoolean(SETUP_FINISHED, false)
        set(v) { prefs.edit().putBoolean(SETUP_FINISHED, v).apply() }

    init {
        // Installs that opened their library before this step existed are set up already.
        if (!prefs.contains(SETUP_FINISHED) && isConfigured && isUnlocked) setupFinished = true
    }

    /** Channels this account owns or administers, libraries first (iOS `candidateChannels`). */
    suspend fun candidateChannels(): List<ChannelChoice> = withContext(Dispatchers.IO) {
        runCatching { td.send(TdApi.LoadChats(TdApi.ChatListMain(), 500)) }
        val chats = td.send(TdApi.GetChats(TdApi.ChatListMain(), 500))
        val out = ArrayList<ChannelChoice>()
        for (id in chats.chatIds) {
            val chat = runCatching { td.send(TdApi.GetChat(id)) }.getOrNull() ?: continue
            val sg = chat.type as? TdApi.ChatTypeSupergroup ?: continue
            if (!sg.isChannel) continue
            val group = runCatching { td.send(TdApi.GetSupergroup(sg.supergroupId)) }.getOrNull() ?: continue
            if (group.status !is TdApi.ChatMemberStatusCreator && group.status !is TdApi.ChatMemberStatusAdministrator) continue
            val found = readHeader(id)
            val h = (found as? HeaderResult.Found)?.header
            val isLibrary = found !is HeaderResult.Missing
            out += ChannelChoice(id, chat.title, isLibrary, h?.encrypted == true)
        }
        out.sortedWith(compareBy({ if (it.isLibrary) 0 else 1 }, { it.title.lowercase() }))
    }

    /**
     * Creates a private channel with a format 2 header: the line in the description and the pinned message (iOS
     * `createLibrary`). Always end-to-end encrypted. Returns the recovery key to show once; nothing stores it.
     */
    suspend fun createLibrary(title: String, passphrase: String): RecoveryKey {
        // Argon2id takes seconds and 256 MiB: done before anything is written, so a failure leaves no empty channel.
        val made = withContext(Dispatchers.Default) { LibraryHeader.newLibrary(passphrase, argon2) }
        return withContext(Dispatchers.IO) {
            val chat = td.send(TdApi.CreateNewSupergroupChat(title, false, true, "Lelvo Library · do not edit\n" + made.header.line, null, 0, false))
            val message = td.sendText(chat.id, made.header.messageText)
            // The description holds the header too, so a library whose pin failed still opens.
            runCatching { td.send(TdApi.PinChatMessage(chat.id, message.id, true, false)) }
                .onFailure { AppLog.warn("Pinning the library header failed") }
            prefs.edit().putLong(CHAT_ID, chat.id).putString(HEADER, made.header.line).putBoolean(SETUP_FINISHED, false).apply()
            storeKeys(made.keys)
            AppLog.info("Created library channel (E2E, header format ${made.header.version})")
            made.recoveryKey
        }
    }

    /**
     * Throws unless this build may write to [chatId]. Every write to a library channel (rename, backups, notes,
     * deletes) asks first: Android must not change a real library before it's proven to write what the iPhone reads.
     */
    suspend fun requireWritable(chatId: Long) {
        if (!guardWrites) return
        val title = withContext(Dispatchers.IO) {
            runCatching { td.send(TdApi.GetChat(chatId)).title }.getOrNull()
                // After a restart TDLib knows the channel only once the chat list is loaded.
                ?: runCatching { td.send(TdApi.LoadChats(TdApi.ChatListMain(), 500)); td.send(TdApi.GetChat(chatId)).title }.getOrNull()
        }
        // Any capitalisation: the owner named it "Android Test". Unknown title (offline) counts as not allowed.
        if (!title?.trim().equals(TEST_LIBRARY, ignoreCase = true)) throw LibraryException.testOnly
    }

    /** Renames the channel. Libraries are recognised by their header, never by name, so this is safe. */
    suspend fun rename(chatId: Long, title: String) = withContext(Dispatchers.IO) {
        val clean = title.trim()
        if (clean.isEmpty()) return@withContext
        requireWritable(chatId)
        td.send(TdApi.SetChatTitle(chatId, clean.take(128)))
        AppLog.info("Renamed library channel")
    }

    /** The pinned header message first, then the channel description (CLOUD_FORMAT.md §1). */
    suspend fun readHeader(chatId: Long): HeaderResult {
        runCatching { td.send(TdApi.OpenChat(chatId)) }
        val pinned = runCatching { td.send(TdApi.GetChatPinnedMessage(chatId)) }.getOrNull()
        val text = (pinned?.content as? TdApi.MessageText)?.text?.text
        if (text != null) {
            val r = LibraryHeader.parse(text)
            if (r !is HeaderResult.Missing) return r
        }
        val chat = runCatching { td.send(TdApi.GetChat(chatId)) }.getOrNull()
        val sg = chat?.type as? TdApi.ChatTypeSupergroup ?: return HeaderResult.Missing
        val info = runCatching { td.send(TdApi.GetSupergroupFullInfo(sg.supergroupId)) }.getOrNull() ?: return HeaderResult.Missing
        return LibraryHeader.parse(info.description)
    }

    /**
     * Uses an existing library. Unlike iOS, a channel without a header is never turned into a library here: Android
     * writes only encrypted libraries, and only through [createLibrary]'s flow.
     */
    suspend fun useExisting(chatId: Long): LibraryHeader {
        val header = when (val r = readHeader(chatId)) {
            is HeaderResult.Found -> r.header
            // Never store it or "repair" it with a header of our own.
            is HeaderResult.Newer -> throw LibraryException.newerVersion
            HeaderResult.Damaged -> throw LibraryException.damaged
            HeaderResult.Missing -> throw LibraryException.notALibrary
        }
        if (!header.encrypted) throw LibraryException.notEncrypted
        val switched = this.chatId != chatId
        prefs.edit().putLong(CHAT_ID, chatId).putString(HEADER, header.line).putBoolean(SETUP_FINISHED, false).apply()
        if (switched) forgetKeys()
        return header
    }

    /**
     * Opens the library with its passphrase or recovery key. Something shaped like a recovery key is tried as one
     * first: that's instant, while Argon2id takes seconds and 256 MiB (iOS learned to order it this way).
     */
    suspend fun unlock(secret: String) {
        val header = header ?: throw LibraryException.notALibrary
        storeKeys(keysFor(header, secret))
    }

    private suspend fun keysFor(header: LibraryHeader, secret: String): E2EKeys = withContext(Dispatchers.Default) {
        when (header) {
            is LibraryHeader.V2 -> RecoveryKey.parse(secret)?.let { header.unlock(it) } ?: header.unlock(secret, argon2)
            is LibraryHeader.V1 -> header.unlock(secret)
            else -> throw LibraryException.notEncrypted
        } ?: throw LibraryException.wrongPassphrase
    }

    /** Another library, opened and checked but not yet in use: the current one stays as it is until [switchTo]. */
    class Opened internal constructor(val chatId: Long, internal val header: LibraryHeader, internal val keys: E2EKeys)

    /**
     * Reads another library's header and checks [secret] against it, changing nothing here. iOS forgets the current
     * library first, so a wrong passphrase left it on the old library without its key; this order can't.
     */
    suspend fun open(chatId: Long, secret: String): Opened {
        val header = when (val r = readHeader(chatId)) {
            is HeaderResult.Found -> r.header
            is HeaderResult.Newer -> throw LibraryException.newerVersion
            HeaderResult.Damaged -> throw LibraryException.damaged
            HeaderResult.Missing -> throw LibraryException.notALibrary
        }
        if (!header.encrypted) throw LibraryException.notEncrypted
        return Opened(chatId, header, keysFor(header, secret))
    }

    /** Uses an opened library from now on. Its index is rebuilt by the next scan (the scanner sees the new chat). */
    fun switchTo(opened: Opened) {
        prefs.edit().putLong(CHAT_ID, opened.chatId).putString(HEADER, opened.header.line).putBoolean(SETUP_FINISHED, true).apply()
        storeKeys(opened.keys)
        AppLog.info("Switched library")
    }

    fun forget() {
        prefs.edit().clear().apply()
        forgetKeys()
    }

    // Passphrase and recovery key (header format 2, CLOUD_FORMAT.md §6.1). The master key never changes, so files,
    // captions and the stored keys stay as they are; only the header is written again.

    /** Format 1: no recovery key, and the passphrase can't change until the header is upgraded. */
    val needsHeaderUpgrade: Boolean get() = header is LibraryHeader.V1

    /**
     * Reads the header from Telegram and keeps it, so changes act on the channel's current header (iOS
     * `refreshHeader`): a copy saved earlier can be stale (another device upgraded the library), and acting on it
     * would replace a header that already has a recovery key with a new one.
     */
    suspend fun refreshHeader(): LibraryHeader {
        val chat = chatId ?: throw LibraryException.noLibrary
        val current = when (val r = withContext(Dispatchers.IO) { readHeader(chat) }) {
            is HeaderResult.Found -> r.header
            is HeaderResult.Newer -> throw LibraryException.newerVersion
            HeaderResult.Damaged -> throw LibraryException.damaged
            HeaderResult.Missing -> throw LibraryException.notALibrary
        }
        if (current != header) prefs.edit().putString(HEADER, current.line).apply()
        return current
    }

    /**
     * A new passphrase; the recovery key keeps working. [current] can also be the recovery key, so someone who forgot
     * the passphrase sets a new one with it. A format 1 library is upgraded on the way and gets a recovery key, which
     * is returned to show; otherwise null.
     */
    suspend fun changePassphrase(current: String, new: String): RecoveryKey? {
        val chat = chatId ?: throw LibraryException.noLibrary
        requireWritable(chat)
        val header = refreshHeader()
        val (changed, recovery) = withContext(Dispatchers.Default) {
            val keys = keysFor(header, current)
            when (header) {
                is LibraryHeader.V1 -> header.upgrading(keys, new, argon2)
                is LibraryHeader.V2 -> header.changingPassphrase(keys, new, argon2) to null
                else -> throw LibraryException.notEncrypted
            }
        }
        replaceHeader(chat, changed)
        AppLog.info("Changed the library passphrase")
        return recovery
    }

    /**
     * A new recovery key; the old one stops working. The passphrase confirms it's the owner asking. A format 1
     * library is upgraded to format 2 on the way (iOS `upgradeHeader`).
     */
    suspend fun newRecoveryKey(passphrase: String): RecoveryKey {
        val chat = chatId ?: throw LibraryException.noLibrary
        requireWritable(chat)
        val header = refreshHeader()
        val (replaced, recovery) = withContext(Dispatchers.Default) {
            when (header) {
                // Only the passphrase here, never a recovery key: this is the step that replaces it.
                is LibraryHeader.V1 -> header.upgrading(header.unlock(passphrase) ?: throw LibraryException.wrongPassphrase, passphrase, argon2)
                is LibraryHeader.V2 -> header.replacingRecoveryKey(header.unlock(passphrase, argon2) ?: throw LibraryException.wrongPassphrase)
                else -> throw LibraryException.notEncrypted
            }
        }
        replaceHeader(chat, replaced)
        AppLog.info(if (header is LibraryHeader.V1) "Upgraded the library header to format 2 (recovery key added)" else "Replaced the library recovery key")
        return recovery
    }

    /**
     * Writes [new] to both places (iOS `replaceHeader`): the description first, then the pinned message edited in
     * place, so the old header doesn't stay readable in the channel. Either partial state still opens with the same
     * master key. Saved here only once Telegram returns exactly this header.
     */
    private suspend fun replaceHeader(chat: Long, new: LibraryHeader.V2) = withContext(Dispatchers.IO) {
        try {
            td.send(TdApi.SetChatDescription(chat, "Lelvo Library · do not edit\n" + new.line))
            val content = TdApi.InputMessageText(TdApi.FormattedText(new.messageText, emptyArray()), null, false)
            val pinned = runCatching { td.send(TdApi.GetChatPinnedMessage(chat)) }.getOrNull()
            val pinnedText = (pinned?.content as? TdApi.MessageText)?.text?.text
            if (pinned != null && pinnedText != null && LibraryHeader.parse(pinnedText) !is HeaderResult.Missing) {
                td.send(TdApi.EditMessageText(chat, pinned.id, null, content))
            } else {
                val message = td.sendText(chat, new.messageText)
                td.send(TdApi.PinChatMessage(chat, message.id, true, false))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppLog.error("Writing the library header failed", e)
            throw LibraryException.headerNotSaved
        }
        if ((readHeader(chat) as? HeaderResult.Found)?.header != new) throw LibraryException.headerNotSaved
        prefs.edit().putString(HEADER, new.line).apply()
    }

    private fun forgetKeys() {
        secrets.delete(MASTER_KEY)
        prefs.edit().remove(KEYS_CHAT_ID).apply()
        cachedKeys = null
    }

    private fun storeKeys(keys: E2EKeys) {
        secrets.write(MASTER_KEY, keys.master)
        chatId?.let { prefs.edit().putLong(KEYS_CHAT_ID, it).apply() }
        cachedKeys = keys
        AppLog.info("Library unlocked")
    }

    private val argon2 = Argon2id { password, salt, t, m, p, length ->
        // argon2kt runs natively and allocates outside the Java heap, so the 256 MiB cost fits on any phone.
        Argon2Kt().hash(Argon2Mode.ARGON2_ID, password, salt, t, m, p, length).rawHashAsByteArray()
    }

    private companion object {
        const val CHAT_ID = "chatId"
        const val HEADER = "header"
        const val KEYS_CHAT_ID = "keysChatId"
        const val MASTER_KEY = "e2e-master-key"
        const val SETUP_FINISHED = "setupFinished"
        const val TEST_LIBRARY = "Android test"
    }
}
