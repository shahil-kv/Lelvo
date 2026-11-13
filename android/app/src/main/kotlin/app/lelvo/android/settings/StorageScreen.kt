package app.lelvo.android.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import app.lelvo.android.LelvoApp
import app.lelvo.android.shell.Messages
import app.lelvo.data.media.CloudMedia
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val MEDIA_LIMITS = listOf(250, 500, 1000, 2000, 5000)
private val THUMBNAIL_LIMITS = listOf(100, 300, 600, 1000)
private fun mbText(mb: Int) = if (mb >= 1000) "${mb / 1000} GB" else "$mb MB"

/**
 * Cache sizes, limits and clearing (iOS `StorageSettingsView`). Clearing never touches the phone's photos or the
 * backup: only previews of cloud items, which download again when they're opened.
 */
@Composable
internal fun StorageScreen(app: LelvoApp, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var usage by remember { mutableStateOf<CloudMedia.Usage?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    var mediaMB by remember { mutableIntStateOf(app.prefs.cacheCapMB) }
    var thumbMB by remember { mutableIntStateOf(app.prefs.thumbnailCacheMB) }
    var picking by remember { mutableStateOf<String?>(null) }
    var clearing by remember { mutableStateOf(false) }
    LaunchedEffect(refresh) { usage = withContext(Dispatchers.IO) { app.media.usage() } }

    fun size(pick: (CloudMedia.Usage) -> Long) = usage?.let { bytesText(context, pick(it)) } ?: "…"
    fun limitsChanged() = scope.launch { withContext(Dispatchers.IO) { app.media.enforceLimits() }; refresh++ }

    SettingsPage("Storage", onBack) {
        SectionHeader("Used on this phone")
        SettingRow("Thumbnails", size { it.thumbnails })
        SettingRow("Viewed photos", size { it.originals })
        SettingRow("Videos and Telegram files", size { it.telegram })
        SettingRow("Clear", if (clearing) "Clearing…" else null, destructive = true, enabled = !clearing) {
            clearing = true
            scope.launch {
                withContext(Dispatchers.IO) {
                    app.media.clearAll()
                    // Coil keeps decoded thumbnails of its own; they'd show until the next launch otherwise.
                    coil3.SingletonImageLoader.get(context).let { it.memoryCache?.clear(); it.diskCache?.clear() }
                }
                clearing = false
                refresh++
                Messages.show(Messages.Style.Success, "Cleared")
            }
        }
        Footnote("Previews of cloud items you've viewed, kept so they open instantly next time. Clearing never touches your photos or your backup.")

        SectionDivider()
        SectionHeader("Limits")
        SettingRow("Viewed photos and videos", mbText(mediaMB)) { picking = "media" }
        SettingRow("Thumbnails", mbText(thumbMB)) { picking = "thumbnails" }
        Footnote("The oldest previews are removed automatically past these limits.")
    }

    when (picking) {
        "media" -> ChoiceDialog("Viewed photos and videos", MEDIA_LIMITS.map { it to mbText(it) }, mediaMB, { picking = null }) {
            mediaMB = it; app.prefs.cacheCapMB = it; limitsChanged()
        }
        "thumbnails" -> ChoiceDialog("Thumbnails", THUMBNAIL_LIMITS.map { it to mbText(it) }, thumbMB, { picking = null }) {
            thumbMB = it; app.prefs.thumbnailCacheMB = it; limitsChanged()
        }
    }
}

/** The Storage row's value on the main Settings page: everything the caches hold. */
@Composable
internal fun storageTotal(app: LelvoApp): String {
    val context = LocalContext.current
    var total by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(Unit) { total = withContext(Dispatchers.IO) { app.media.usage().total } }
    return total?.let { bytesText(context, it) } ?: "…"
}
