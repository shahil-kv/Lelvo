package app.lelvo.android.settings

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.background.DeviceState
import app.lelvo.core.backup.BackgroundIssue
import app.lelvo.core.backup.BackgroundRuns
import app.lelvo.core.backup.RunSource
import app.lelvo.data.media.PhotoAccess

/** What Android will let background backup do, and the words for the Backup tab and Settings. */
object BackgroundStatus {
    fun issue(app: LelvoApp, waiting: Int): BackgroundIssue {
        val context = app.applicationContext
        val last = app.prefs.runRecords
            .filter { it.source != RunSource.User && it.source != RunSource.Refresh && it.uploaded > 0 }
            .maxOfOrNull { it.startedAt }
            ?: System.currentTimeMillis()
        return BackgroundRuns.backgroundIssue(
            partialAccess = app.photos.status() == PhotoAccess.Status.Partial,
            restricted = DeviceState.backgroundRestricted(context),
            optimized = !DeviceState.ignoringBatteryOptimizations(context),
            bucket = DeviceState.standbyBucket(context),
            lastExitForceStop = DeviceState.lastExitWasForceStop(context),
            lastAutoUpload = last,
            waiting = waiting,
            now = System.currentTimeMillis(),
        )
    }

    fun label(issue: BackgroundIssue): String = when (issue) {
        BackgroundIssue.None -> "Working"
        BackgroundIssue.BatteryOptimized, BackgroundIssue.RareBucket, BackgroundIssue.PartialPhotoAccess -> "Limited"
        else -> "Off"
    }

    fun body(issue: BackgroundIssue): String? = when (issue) {
        BackgroundIssue.PartialPhotoAccess -> "Lelvo can only see the photos you selected. New photos aren't backed up."
        BackgroundIssue.BackgroundRestricted -> "Android stopped Lelvo from running in the background, so new photos wait until you open it."
        BackgroundIssue.BatteryOptimized, BackgroundIssue.RareBucket -> "Photos have waited since yesterday. Your phone may be saving battery by stopping Lelvo."
        BackgroundIssue.ForceStopped -> "Automatic backup stops when Lelvo is force-stopped. It started again now that Lelvo is open."
        BackgroundIssue.None -> null
    }

    fun makerLine(): String? = when (Build.MANUFACTURER.lowercase()) {
        "samsung" -> "Also remove Lelvo from Sleeping apps in Battery settings."
        "xiaomi", "redmi", "poco" -> "Also turn on Autostart for Lelvo."
        else -> null
    }
}

@Composable
fun BackgroundIssueCard(issue: BackgroundIssue, onDismissForceStop: () -> Unit) {
    val text = BackgroundStatus.body(issue) ?: return
    val context = LocalContext.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceVariant) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(text)
                if (issue == BackgroundIssue.BatteryOptimized || issue == BackgroundIssue.RareBucket) {
                    BackgroundStatus.makerLine()?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    when (issue) {
                        BackgroundIssue.PartialPhotoAccess -> Button(onClick = { openAppSettings(context) }) { Text("Allow all photos") }
                        BackgroundIssue.BackgroundRestricted, BackgroundIssue.BatteryOptimized, BackgroundIssue.RareBucket ->
                            Button(onClick = { openAppSettings(context) }) { Text("Fix") }
                        BackgroundIssue.ForceStopped -> TextButton(onClick = onDismissForceStop) { Text("Dismiss") }
                        BackgroundIssue.None -> Unit
                    }
                    if (issue == BackgroundIssue.BatteryOptimized || issue == BackgroundIssue.RareBucket) {
                        TextButton(onClick = { openLink(context, "https://dontkillmyapp.com/${Build.MANUFACTURER.lowercase()}") }) { Text("More help") }
                    }
                }
            }
        }
    }
}

@Composable
fun BackgroundBackupScreen(app: LelvoApp, onBack: () -> Unit) {
    val issue by androidx.compose.runtime.produceState(BackgroundIssue.None) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { BackgroundStatus.issue(app, app.backup.readyCount()) }
    }
    val last = app.prefs.runRecords
        .filter { it.source != RunSource.User && it.source != RunSource.Refresh }
        .maxByOrNull { it.startedAt }
    val whenLast = last?.let {
        DateUtils.getRelativeTimeSpanString(it.startedAt, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
    }
    SettingsPage("Background backup", onBack) {
        BackgroundStatus.body(issue)?.let { Text(it, modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) }
        if (issue == BackgroundIssue.None) {
            Text("Background backup can run on this phone.", modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp))
        }
        if (issue == BackgroundIssue.BatteryOptimized || issue == BackgroundIssue.RareBucket) {
            BackgroundStatus.makerLine()?.let { Footnote(it) }
            val context = LocalContext.current
            TextButton(onClick = { openLink(context, "https://dontkillmyapp.com/${Build.MANUFACTURER.lowercase()}") }) { Text("More help") }
            TextButton(onClick = { openAppSettings(context) }) { Text("Fix") }
        }
        Footnote(if (whenLast == null) "No automatic backup yet." else "Last automatic backup: $whenLast.")
    }
}

private fun openAppSettings(context: android.content.Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    context.startActivity(intent)
}
