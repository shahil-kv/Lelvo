package app.lelvo.android

import android.app.Application
import android.os.Build
import app.lelvo.data.SecretStore
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TelegramConfig
import java.util.Locale

/** Creates the services once per process; screens and background work share them (like iOS AppEnvironment). */
class LelvoApp : Application() {
    lateinit var secrets: SecretStore private set
    lateinit var telegram: TdClient private set

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
    }
}
