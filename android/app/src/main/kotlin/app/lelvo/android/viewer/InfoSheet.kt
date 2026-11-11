package app.lelvo.android.viewer

import androidx.compose.runtime.getValue
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.text.format.DateFormat
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.shell.Messages
import app.lelvo.android.timeline.icon
import app.lelvo.android.timeline.listTint
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.index.GalleryEntry
import app.lelvo.data.media.MediaDetails
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Details, the way Google Photos shows them when you swipe up: rows with an icon, for the date, the file, the camera
 * and the place, then what the backup knows (iOS `InfoSheet`, same facts and words).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InfoSheet(entry: GalleryEntry, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as LelvoApp
    val locale = context.resources.configuration.locales[0]
    val item = entry.item
    val asset = entry.asset
    // The file itself has the camera and, on the phone, the folder; a cloud photo only once it was opened.
    val details by produceState(MediaDetails(), entry.id) {
        value = when {
            asset != null -> app.details.phone(app.photos.uri(asset), asset.isVideo)
            item != null && !entry.isVideo -> app.media.cachedDisplayed(item)?.let { app.details.file(it) } ?: MediaDetails()
            else -> MediaDetails()
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 16.dp)) {
            Text(
                "Details", style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp).semantics { heading() },
            )
            entry.date?.let { ms ->
                val zone = item?.tzOffsetMinutes?.let { ZoneOffset.ofTotalSeconds(it * 60) } ?: ZoneId.systemDefault()
                val at = Instant.ofEpochMilli(ms).atZone(zone)
                val day = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "EEEEdMMMMyyyy"), locale).format(at)
                val time = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "jmm"), locale).format(at)
                Row(R.drawable.ic_calendar, day, "$time · GMT${at.offset.id.takeIf { it != "Z" } ?: ""}")
            } ?: Row(R.drawable.ic_calendar, "Unknown date", null)

            val name = item?.filename ?: asset?.filename
            val w = asset?.width?.takeIf { it > 0 } ?: item?.width ?: 0
            val h = asset?.height?.takeIf { it > 0 } ?: item?.height ?: 0
            val bytes = details.size ?: item?.let { it.fileSize + (it.pairedVideoSize ?: 0) }
            val fileLine = buildList {
                if (w > 0 && h > 0 && !entry.isVideo) add(megapixels(w, h))
                if (w > 0 && h > 0) add("$w × $h")
                bytes?.let { add(Formatter.formatShortFileSize(context, it)) }
                if (entry.isVideo) entry.duration?.let { add(DateUtils.formatElapsedTime(Math.round(it))) }
            }.joinToString(" · ")
            Row(if (entry.isVideo) R.drawable.ic_play else R.drawable.ic_image, name?.ifEmpty { null } ?: if (entry.isVideo) "Video" else "Photo", fileLine.ifEmpty { null })
            val format = listOfNotNull(
                item?.codec?.uppercase(Locale.ROOT),
                item?.hdr?.takeIf { it > 0 }?.let { if (it == 2) "Dolby Vision" else "HDR" },
            ).joinToString(" · ")
            if (format.isNotEmpty()) Row(R.drawable.ic_motion_photos, format, null)
            details.camera?.let { Row(R.drawable.ic_photo_camera, it, details.exposure) }

            val lat = details.latitude ?: item?.latitude
            val lon = details.longitude ?: item?.longitude
            if (lat != null && lon != null) {
                val coordinates = String.format(Locale.ROOT, "%.5f, %.5f", lat, lon)
                Row(R.drawable.ic_place, coordinates, "Open in Maps") {
                    // No map inside the app: Lelvo sends nothing to a map service itself. The user's maps app opens it.
                    val label = Uri.encode(name ?: "Photo")
                    try {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=${lat},${lon}($label)")))
                    } catch (_: ActivityNotFoundException) {
                        Messages.show(Messages.Style.Info, "No maps app on this phone")
                    }
                }
            }
            details.folder?.let { Row(R.drawable.ic_phone, "On this phone", it) }

            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            Text(
                "Backup", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp).semantics { heading() },
            )
            val badge = entry.badge
            Row(badge.icon, badge.label, badge.explanation, tint = badge.listTint())
            if (item != null) {
                item.uploadedAt?.let { Row(R.drawable.ic_cloud_upload, "Uploaded", DateUtils.formatDateTime(context, it, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_YEAR or DateUtils.FORMAT_SHOW_TIME)) }
                if (item.encrypted) Row(R.drawable.ic_lock, "End-to-end encrypted", "Only your passphrase can open it.")
                item.verifiedAt?.let { Row(R.drawable.ic_check_circle, "Verified", DateUtils.getRelativeTimeSpanString(it).toString()) }
                item.lastError?.let { Row(R.drawable.ic_error, it, null, tint = Lelvo.colors.orange) }
            }
        }
    }
}

@Composable
private fun Row(icon: Int, title: String, detail: String?, tint: Color? = null, onClick: (() -> Unit)? = null) {
    val click = if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier
    Row(
        click.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(icon), null, Modifier.size(24.dp), tint = tint ?: MaterialTheme.colorScheme.onSurfaceVariant)
        Column(Modifier.padding(start = 24.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            detail?.let {
                Text(
                    it, style = MaterialTheme.typography.bodyMedium,
                    color = if (onClick != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

private fun megapixels(w: Int, h: Int): String {
    val mp = w.toLong() * h / 1_000_000.0
    return if (mp >= 10) "${Math.round(mp)} MP" else String.format(Locale.ROOT, "%.1f MP", mp)
}
