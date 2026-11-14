package app.lelvo.android.debug

import android.text.format.DateUtils
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.background.BackupScheduler
import app.lelvo.android.background.BackupWorker
import app.lelvo.android.background.DeviceState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Debug only. Runs each background job now and shows why the last ones stopped, so a phone can be
 * checked without reading logcat. Uses its own work names, so it does not replace the real schedule.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackgroundLabScreen(app: LelvoApp, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    var tick by remember { mutableIntStateOf(0) }
    var jobs by remember { mutableStateOf(emptyList<String>()) }
    val records = remember(tick) { app.prefs.runRecords.takeLast(20).asReversed() }
    LaunchedEffect(tick) {
        jobs = withContext(Dispatchers.IO) {
            val wm = WorkManager.getInstance(context)
            listOf(BackupScheduler.USER, BackupScheduler.NEW_PHOTOS, BackupScheduler.AUTO_RUN, BackupScheduler.OVERNIGHT, BackupScheduler.REFRESH).map { name ->
                val info = wm.getWorkInfosForUniqueWork(name).get().firstOrNull { !it.state.isFinished }
                val whenNext = info?.nextScheduleTimeMillis?.takeIf { it > 0 }?.let { DateUtils.getRelativeTimeSpanString(it) }
                "$name  ${info?.state ?: "none"}${whenNext?.let { "  next $it" } ?: ""}"
            }
        }
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Background lab") },
                navigationIcon = {
                    IconButton(onClick = onClose) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Photos: ${app.photos.status()}")
            Text("Battery unrestricted: ${DeviceState.ignoringBatteryOptimizations(context)}")
            Text("Background restricted: ${DeviceState.backgroundRestricted(context)}")
            Text("Standby bucket: ${DeviceState.standbyBucket(context)}")
            Text("Last exit was a force stop: ${DeviceState.lastExitWasForceStop(context)}")
            Text("Telegram wait until: ${app.prefs.floodUntil.takeIf { it > 0 } ?: "none"}")
            listOf(
                "Run new-photos job now" to BackupScheduler.NEW_PHOTOS,
                "Run automatic run now" to BackupScheduler.AUTO_RUN,
                "Run overnight now" to BackupScheduler.OVERNIGHT,
                "Run refresh now" to BackupScheduler.REFRESH,
            ).forEach { (label, kind) ->
                Button(onClick = { enqueue(context, kind); tick++ }, modifier = Modifier.fillMaxWidth()) { Text(label) }
            }
            Button(onClick = { tick++ }, modifier = Modifier.fillMaxWidth()) { Text("Refresh") }
            Text("Scheduled")
            jobs.forEach { Text(it) }
            Text("Last runs")
            if (records.isEmpty()) Text("No runs yet.")
            records.forEach { r ->
                ListItem(
                    headlineContent = { Text("${r.source}  ${r.stop ?: ""}") },
                    supportingContent = {
                        Text("${DateUtils.getRelativeTimeSpanString(r.startedAt)}  ${r.seconds.toInt()} s  uploaded ${r.uploaded}  ${r.remaining} waiting")
                    },
                )
            }
        }
    }
}

private fun enqueue(context: android.content.Context, kind: String) {
    val request = OneTimeWorkRequestBuilder<BackupWorker>()
        .setInputData(workDataOf(BackupWorker.KIND to kind))
        .build()
    WorkManager.getInstance(context).enqueueUniqueWork("lab.$kind", ExistingWorkPolicy.APPEND_OR_REPLACE, request)
}
