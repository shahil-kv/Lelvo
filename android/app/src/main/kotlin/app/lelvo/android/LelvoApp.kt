package app.lelvo.android

import android.app.Application
import android.os.Build
import android.util.Log
import app.lelvo.core.support.AppLog
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
import app.lelvo.telegram.AuthStep
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TdFiles
import app.lelvo.telegram.TelegramConfig
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

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
    lateinit var model: AppModel private set
    lateinit var photos: app.lelvo.data.media.PhotoAccess private set
    lateinit var linker: app.lelvo.data.media.PhotoLinker private set
    lateinit var reader: app.lelvo.data.media.MediaReader private set
    lateinit var media: app.lelvo.data.media.CloudMedia private set
    lateinit var positions: app.lelvo.data.media.PlaybackPositions private set
    /** The launch opening plays once per process (cold start only). */
    var openingPlayed = false

    override fun onCreate() {
        super.onCreate()
        // Logs stay out of Android backup, like the secrets; only the user shares them (Settings → Logs).
        AppLog.install(
            dir = java.io.File(noBackupFilesDir, "logs"),
            secrets = { listOf(BuildConfig.TELEGRAM_API_HASH).filter { it.isNotBlank() } },
            // Debug builds echo to logcat, like iOS prints to the device console in Debug.
            echo = if (BuildConfig.DEBUG) { level, line ->
                when (level) {
                    AppLog.Level.INFO -> Log.i("Lelvo", line)
                    AppLog.Level.WARN -> Log.w("Lelvo", line)
                    AppLog.Level.ERROR -> Log.e("Lelvo", line)
                }
            } else null,
        )
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
        scanner = LibraryScanner(files, library, store, telegram).also { it.follow() }
        coreCheck = CoreCheck(files, library, scanner, store)
        photos = app.lelvo.data.media.PhotoAccess(this)
        linker = app.lelvo.data.media.PhotoLinker(store, photos)
        reader = app.lelvo.data.media.MediaReader(files, library, telegram)
        media = app.lelvo.data.media.CloudMedia(this, reader, prefs)
        positions = app.lelvo.data.media.PlaybackPositions(this)
        model = AppModel(this)
    }

    /**
     * Sign out and reset, like iOS `AppEnvironment.resetEverything`: Telegram signs out (TDLib removes its own data),
     * then the index, the library's keys, the cached images and every setting go. The channel isn't touched.
     * [keepingChoices]: the user didn't ask (the session ended elsewhere). Nothing on Android needs keeping yet; the
     * Recently Deleted and favorites choices come with their notes (Phases C and L).
     */
    suspend fun resetEverything(keepingChoices: Boolean) {
        AppLog.info("Reset this phone: signing out and removing Lelvo's local data${if (keepingChoices) " (session ended elsewhere)" else ""}")
        demo.exit()
        // Telegram is asked only when a session or a sign-in is under way; in the demo it usually isn't.
        if (telegram.auth.value !in listOf(AuthStep.WaitPhone, AuthStep.NeedsCredentials, AuthStep.Closed)) telegram.logOut()
        withContext(Dispatchers.IO) {
            store.deleteAll()
            library.forget()
            prefs.reset()
            SingletonImageLoader.get(this@LelvoApp).let { it.memoryCache?.clear(); it.diskCache?.clear() }
            media.clear()
            positions.clear()
        }
        AppLog.info("Reset finished")
    }

    // Video cells show their first frame.
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context).components {
            add(VideoFrameDecoder.Factory())
            add(app.lelvo.android.media.CloudImageFetcher.ThumbnailFactory(media))
            add(app.lelvo.android.media.CloudImageFetcher.PhotoFactory(media))
            add(app.lelvo.android.media.CloudThumbnailKeyer())
            add(app.lelvo.android.media.CloudPhotoKeyer())
        }.build()

    /** "First Last" of the signed-in account, as Settings shows it; empty when Telegram can't say. */
    suspend fun accountName(): String = runCatching {
        val me = telegram.send(org.drinkless.tdlib.TdApi.GetMe())
        listOf(me.firstName, me.lastName).filter { it.isNotBlank() }.joinToString(" ")
    }.getOrDefault("")

    /** On a metered network (mobile data): nothing is fetched ahead, like iOS on an expensive network. */
    fun isMetered(): Boolean =
        runCatching { getSystemService(android.net.ConnectivityManager::class.java).isActiveNetworkMetered }.getOrDefault(true)

    /** The library channel's name. */
    suspend fun libraryTitle(): String = runCatching {
        val chatId = library.chatId ?: return ""
        // After a restart TDLib knows the channel only once it's loaded.
        files.ensureChat(chatId)
        telegram.send(org.drinkless.tdlib.TdApi.GetChat(chatId)).title
    }.getOrDefault("")
}
