package app.lelvo.android.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.data.Prefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** "Photos and videos, Wi-Fi, charging": the Backup options row's summary, as iOS `backupSummary`. */
internal fun backupSummary(prefs: Prefs): String = buildList {
    add(prefs.mediaFilter.title)
    if (prefs.wifiOnly) add("Wi-Fi")
    if (prefs.chargingOnly) add("charging")
}.joinToString(", ")

/**
 * What gets backed up, and when (iOS `BackupOptionsView`). Android has no hidden photos, so there is no "Include
 * hidden photos". [onRulesChanged] reschedules the background work: `true` when Wi-Fi or charging changed.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BackupOptionsScreen(prefs: Prefs, onAlbums: () -> Unit, onRulesChanged: (rules: Boolean) -> Unit, onBack: () -> Unit) {
    var media by remember { mutableStateOf(prefs.mediaFilter) }
    var screenshots by remember { mutableStateOf(prefs.includeScreenshots) }
    var dateFrom by remember { mutableStateOf(prefs.dateFrom) }
    var wifi by remember { mutableStateOf(prefs.wifiOnly) }
    var charging by remember { mutableStateOf(prefs.chargingOnly) }
    var fast by remember { mutableStateOf(prefs.streamingCopies) }
    var quality by remember { mutableStateOf(prefs.videoQuality) }
    var picking by remember { mutableStateOf<String?>(null) }
    // Changed on the Albums page, which opens over this one.
    val albumMode by produceState(prefs.albumMode) { prefs.changes().collect { value = prefs.albumMode } }

    SettingsPage("Backup options", onBack) {
        SectionHeader("What Back up now includes")
        SettingRow("Back up", media.title) { picking = "media" }
        ToggleRow("Include screenshots", null, screenshots) { screenshots = it; prefs.includeScreenshots = it; onRulesChanged(false) }
        SettingRow("Albums", albumMode.title, onClick = onAlbums)
        ToggleRow("Only photos taken after a date", null, dateFrom != null) { on ->
            // A year back, as iOS starts the picker, until a day is chosen.
            dateFrom = if (on) LocalDate.now().minusYears(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli() else null
            prefs.dateFrom = dateFrom
            onRulesChanged(false)
        }
        dateFrom?.let { from ->
            val shown = remember(from) {
                DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).format(Instant.ofEpochMilli(from).atZone(ZoneId.systemDefault()))
            }
            SettingRow("From", shown) { picking = "date" }
        }

        SectionDivider()
        SectionHeader("When to upload")
        ToggleRow("Wi-Fi only", "Also waits on mobile data, hotspots and other metered networks.", wifi) {
            wifi = it; prefs.wifiOnly = it; onRulesChanged(true)
        }
        ToggleRow("Only while charging", null, charging) { charging = it; prefs.chargingOnly = it; onRulesChanged(true) }

        SectionDivider()
        SectionHeader("Videos")
        ToggleRow("Make fast versions of videos", null, fast) { fast = it; prefs.streamingCopies = it }
        SettingRow("Play cloud videos", quality.label) { picking = "quality" }
        Footnote(
            "A fast version is a small copy (about a tenth of the size) made while a video is backed up, so it plays at once " +
                "from your Telegram library. The original is always kept. Automatic plays the fast version when the " +
                "connection is too slow for the original; you can switch in the video at any time.",
        )
    }

    when (picking) {
        "media" -> ChoiceDialog("Back up", Prefs.MediaFilter.entries.map { it to it.title }, media, { picking = null }) {
            media = it; prefs.mediaFilter = it; onRulesChanged(false)
        }
        "quality" -> ChoiceDialog(
            "Play cloud videos", listOf(Prefs.VideoQuality.Automatic, Prefs.VideoQuality.Original).map { it to it.label },
            quality, { picking = null },
        ) { quality = it; prefs.videoQuality = it }
        "date" -> {
            // The picker works in UTC days; the setting is the start of that day here.
            val state = rememberDatePickerState(
                initialSelectedDateMillis = dateFrom?.let {
                    Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault()).toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
                },
            )
            DatePickerDialog(
                onDismissRequest = { picking = null },
                confirmButton = {
                    TextButton(onClick = {
                        state.selectedDateMillis?.let { utc ->
                            val day = Instant.ofEpochMilli(utc).atZone(ZoneOffset.UTC).toLocalDate()
                            dateFrom = day.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
                            prefs.dateFrom = dateFrom
                            onRulesChanged(false)
                        }
                        picking = null
                    }) { Text("OK") }
                },
                dismissButton = { TextButton(onClick = { picking = null }) { Text("Cancel") } },
            ) { DatePicker(state) }
        }
    }
}

private val Prefs.VideoQuality.label: String
    get() = when (this) {
        Prefs.VideoQuality.Original -> "Original Quality"
        Prefs.VideoQuality.Fast -> "Fast version"
        Prefs.VideoQuality.Automatic -> "Automatic"
    }

/** The phone's folders the backup includes or leaves out (iOS `AlbumPickerView`; Android's albums are folders). */
@Composable
internal fun AlbumPickerScreen(app: LelvoApp, onChanged: () -> Unit, onBack: () -> Unit) {
    val prefs = app.prefs
    var mode by remember { mutableStateOf(prefs.albumMode) }
    var selected by remember { mutableStateOf(prefs.albumIds) }
    val folders by produceState<List<Triple<String, String, Int>>?>(null) {
        value = withContext(Dispatchers.IO) {
            runCatching { app.backup.phone.all() }.getOrDefault(emptyList())
                .filter { it.bucketId != null }
                .groupBy { it.bucketId!! }
                .map { (id, files) -> Triple(id, files.first().bucketName ?: "Unnamed folder", files.size) }
                .sortedBy { it.second.lowercase() }
        }
    }
    SettingsPage("Albums", onBack) {
        SectionHeader("Back up")
        Prefs.AlbumMode.entries.forEach { m ->
            ListItem(
                headlineContent = { Text(m.title) },
                leadingContent = { androidx.compose.material3.RadioButton(selected = m == mode, onClick = null) },
                modifier = Modifier.clickable(role = Role.RadioButton) { mode = m; prefs.albumMode = m; onChanged() },
            )
        }
        if (mode != Prefs.AlbumMode.All) {
            SectionDivider()
            SectionHeader(if (mode == Prefs.AlbumMode.Include) "Include" else "Exclude")
            val list = folders
            when {
                list == null -> Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.padding(2.dp), strokeWidth = 2.dp)
                    Text("Looking for folders…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                list.isEmpty() -> Footnote("No folders with photos on this phone, or Lelvo can't see your photos.")
                else -> list.forEach { (id, name, count) ->
                    val on = id in selected
                    ListItem(
                        headlineContent = { Text(name) },
                        supportingContent = { Text("$count", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                        trailingContent = { Checkbox(checked = on, onCheckedChange = null) },
                        modifier = Modifier.clickable(role = Role.Checkbox) {
                            selected = if (on) selected - id else selected + id
                            prefs.albumIds = selected
                            onChanged()
                        },
                    )
                }
            }
        }
    }
}
