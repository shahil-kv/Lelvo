package app.lelvo.android

import android.app.Application
import android.os.Build
import app.lelvo.data.CoreCheck
import app.lelvo.data.DemoMode
import app.lelvo.data.LibraryScanner
import app.lelvo.data.Prefs
import app.lelvo.data.LibraryService
import app.lelvo.data.index.IndexDatabase
import app.lelvo.data.index.LibraryStore
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.video.VideoFrameDecoder
import app.lelvo.data.SecretStore
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TdFiles
import app.lelvo.telegram.TelegramConfig
import java.util.Locale

/** Creates the services once per process; screens and background work share them (like iOS AppEnvironment). */
class LelvoApp : Application(), SingletonImageLoader.Factory {
    lateinit var secrets: SecretStore private set
    lateinit var telegram: TdClient private set
    lateinit var library: LibraryService private set
    lateinit var store: LibraryStore private set
    lateinit var demo: DemoMode private set
    lateinit var prefs: Prefs private set
    lateinit var files: TdFiles private set
    lateinit var scanner: LibraryScanner private set
    lateinit var coreCheck: CoreCheck private set

    override fun onCreate() {
        super.onCreate()
        secrets = SecretStore(this)
        val config = BuildConfig.TELEGRAM_API_ID.takeIf { it != 0 && BuildConfig.TELEGRAM_API_HASH.isNotBlank() }?.let {
            TelegramConfig(
                apiId = it,
                apiHash = BuildConfig.TELEGRAM_API_HASH,
                useTestDc = BuildConfig.TELEGRAM_TEST_DC,
                dataDir = noBackupFilesDir,
                cacheDir = cacheDir,
                // Shown in Telegram → Settings → Devices.
                deviceModel = "Android",
                appVersion = BuildConfig.VERSION_NAME,
                languageCode = Locale.getDefault().language.ifBlank { "en" },
            )
        }
        telegram = TdClient(config, secrets.telegramDatabaseKeys())
        telegram.start()
        library = LibraryService(this, telegram, secrets)
        store = LibraryStore(IndexDatabase.open(this))
        demo = DemoMode(this, store)
        prefs = Prefs(this)
        files = TdFiles(telegram)
        scanner = LibraryScanner(files, library, store)
        coreCheck = CoreCheck(files, library, scanner, store)
    }

    // Video cells show their first frame.
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context).components { add(VideoFrameDecoder.Factory()) }.build()

    /** "First Last" of the signed-in account, as Settings shows it; empty when Telegram can't say. */
    suspend fun accountName(): String = runCatching {
        val me = telegram.send(org.drinkless.tdlib.TdApi.GetMe())
        listOf(me.firstName, me.lastName).filter { it.isNotBlank() }.joinToString(" ")
    }.getOrDefault("")

    /** The library channel's name. */
    suspend fun libraryTitle(): String = runCatching {
        val chatId = library.chatId ?: return ""
        // After a restart TDLib knows the channel only once it's loaded.
        files.ensureChat(chatId)
        telegram.send(org.drinkless.tdlib.TdApi.GetChat(chatId)).title
    }.getOrDefault("")
}
