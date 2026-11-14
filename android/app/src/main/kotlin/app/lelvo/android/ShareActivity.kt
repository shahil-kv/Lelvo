package app.lelvo.android

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.android.ui.theme.LelvoTheme
import app.lelvo.core.support.AppLog
import app.lelvo.data.media.SharedIntake
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch

/**
 * "Lelvo" in another app's share sheet: backs the shared photos and videos up to the user's Telegram library.
 * A separate, see-through activity, so sharing never replaces what the user had open in Lelvo, and the sharing app's
 * read grant stays alive while the files are read (it ends when this activity finishes).
 */
class ShareActivity : ComponentActivity() {
    private sealed interface Step {
        data object NotReady : Step
        data object Nothing : Step
        data class Ready(val uris: List<Uri>) : Step
        data class Working(val done: Int, val total: Int) : Step
        data class Done(val queued: Int, val skipped: Int) : Step
    }

    private var step by mutableStateOf<Step>(Step.Nothing)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as LelvoApp
        val intake = SharedIntake(this)
        read(app, intake, intent)
        setContent { LelvoTheme { Sheet(app, intake) } }
    }

    // A second share while the sheet is open replaces the first, unless its files are being read right now.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (step is Step.Working) return
        setIntent(intent)
        read(application as LelvoApp, SharedIntake(this), intent)
    }

    private fun read(app: LelvoApp, intake: SharedIntake, intent: Intent?) {
        val uris = sharedUris(intent).filter(intake::isMedia)
        val ready = app.library.isConfigured && app.library.isUnlocked && app.library.setupFinished && !app.demo.active.value
        step = when {
            !ready -> Step.NotReady
            uris.isEmpty() -> Step.Nothing
            else -> Step.Ready(uris)
        }
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun Sheet(app: LelvoApp, intake: SharedIntake) {
        val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        val scope = rememberCoroutineScope()
        val haptics = LocalHapticFeedback.current
        val close = { scope.launch { sheet.hide() }.invokeOnCompletion { finish() } }
        ModalBottomSheet(
            onDismissRequest = { if (step !is Step.Working) finish() },
            sheetState = sheet,
        ) {
            AnimatedContent(step, contentKey = { it::class }, label = "share step") { s ->
                Column(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    when (s) {
                        Step.NotReady -> {
                            Title(R.drawable.ic_cloud_upload, "Set up Lelvo first")
                            Body("Open Lelvo and finish setting up your Telegram library. Then share these photos again.")
                            Primary("Open Lelvo") { openLelvo(null); finish() }
                            Secondary("Not now") { close() }
                        }
                        Step.Nothing -> {
                            Title(R.drawable.ic_cloud_upload, "Nothing to back up")
                            Body("Lelvo backs up photos and videos. The shared files aren't either.")
                            Primary("OK") { close() }
                        }
                        is Step.Ready -> {
                            val n = s.uris.size
                            Title(R.drawable.ic_cloud_upload, "Back up ${count(n)}")
                            Previews(s.uris)
                            Body("They go to your Telegram library, end-to-end encrypted. Ones that aren't in this phone's photos yet are saved to Pictures › Lelvo too.")
                            Primary("Back up") {
                                step = Step.Working(0, n)
                                lifecycleScope.launch {
                                    val result = runCatching {
                                        intake.prepare(s.uris) { done -> runOnUiThread { step = Step.Working(done, n) } }
                                    }.onFailure { AppLog.warn("Couldn't add shared files", it) }.getOrNull()
                                    val queued = if (result == null || result.localIds.isEmpty()) 0 else app.backup.enqueue(result.localIds)
                                    // Already backed up counts as done: the user's photos are safe either way.
                                    val ready = result?.localIds?.size ?: 0
                                    if (queued > 0) app.startBackup(includeNew = false)
                                    haptics.performHapticFeedback(if (ready > 0) HapticFeedbackType.Confirm else HapticFeedbackType.Reject)
                                    step = Step.Done(queued, n - ready)
                                }
                            }
                            Secondary("Cancel") { close() }
                        }
                        is Step.Working -> {
                            Title(R.drawable.ic_cloud_upload, "Adding ${count(s.total)}…")
                            LinearProgressIndicator(
                                progress = { if (s.total == 0) 0f else s.done.toFloat() / s.total },
                                modifier = Modifier.fillMaxWidth(), color = Lelvo.colors.accent,
                            )
                            Body("Keep this open for a moment.")
                        }
                        is Step.Done -> {
                            when {
                                s.queued > 0 -> {
                                    Title(R.drawable.ic_cloud_done, "Backing up ${count(s.queued)}")
                                    Body("You can close this. Lelvo keeps going and tells you when it's done.")
                                }
                                s.skipped == 0 -> {
                                    Title(R.drawable.ic_cloud_done, "Already backed up")
                                    Body("These are in your Telegram library already.")
                                }
                                else -> {
                                    Title(R.drawable.ic_cloud_off, "Couldn't add these")
                                    Body("Lelvo couldn't read the shared files, or the phone is low on space. Free up some space, or save them to your phone first and back them up from Lelvo.")
                                }
                            }
                            if (s.queued > 0 && s.skipped > 0) Body("${count(s.skipped)} couldn't be added and were left out. The phone may be low on space.")
                            Primary("Done") { close() }
                            if (s.queued > 0) Secondary("Open Backup") { openLelvo(MainActivity.ACTION_OPEN_BACKUP); finish() }
                        }
                    }
                }
            }
        }
    }

    @Composable
    private fun Title(icon: Int, text: String) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.size(48.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape), contentAlignment = Alignment.Center) {
                Icon(painterResource(icon), contentDescription = null, tint = Lelvo.colors.accent)
            }
            Text(text, style = MaterialTheme.typography.headlineSmall, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.semantics { heading() })
        }
    }

    @Composable
    private fun Body(text: String) =
        Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)

    @Composable
    private fun Primary(text: String, onClick: () -> Unit) = Button(
        onClick = onClick, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Lelvo.colors.accent),
    ) { Text(text) }

    @Composable
    private fun Secondary(text: String, onClick: () -> Unit) =
        TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(text) }

    @Composable
    private fun Previews(uris: List<Uri>) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            itemsIndexed(uris.take(30), key = { i, u -> "$i$u" }) { _, uri ->
                AsyncImage(
                    model = uri, contentDescription = null, contentScale = ContentScale.Crop,
                    modifier = Modifier.size(88.dp).clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
                )
            }
        }
    }

    private fun openLelvo(action: String?) {
        startActivity(Intent(this, MainActivity::class.java).apply {
            this.action = action
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        })
    }

    private fun count(n: Int) = if (n == 1) "1 item" else "$n items"

    private fun sharedUris(intent: Intent?): List<Uri> {
        intent ?: return emptyList()
        return when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM),
            )
            Intent.ACTION_SEND_MULTIPLE ->
                (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)).orEmpty()
            else -> emptyList()
        }.distinct()
    }
}
