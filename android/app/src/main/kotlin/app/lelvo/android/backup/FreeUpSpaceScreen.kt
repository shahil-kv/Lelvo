package app.lelvo.android.backup

import android.app.Activity
import android.os.Build
import android.provider.MediaStore
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.brand.CatchingBurst
import app.lelvo.android.brand.CatchingMark
import app.lelvo.android.brand.CatchingStatus
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.android.ui.theme.rememberReduceMotion
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.toBitmap
import app.lelvo.android.shell.Messages
import app.lelvo.core.backup.FreeUpSpace
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Free up space (iOS `FreeUpSpaceView`): removes photos already safely backed up from the phone. Every item is checked
 * in Telegram first; the removal is Android's own trash prompt, so nothing goes without the user's yes, and Android
 * keeps them in its trash for 30 days. They stay in Lelvo as cloud items.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FreeUpSpaceScreen(app: LelvoApp, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val service = app.freeUpSpace
    var candidates by remember { mutableStateOf<List<LibraryItem>?>(null) }
    var verified by remember { mutableStateOf<List<LibraryItem>>(emptyList()) }
    var checked by remember { mutableIntStateOf(0) }
    var checking by remember { mutableStateOf<Job?>(null) }
    var removing by remember { mutableStateOf<List<LibraryItem>>(emptyList()) }
    var freed by remember { mutableStateOf<Pair<Int, Long>?>(null) }
    // The freed space counts up while the removed photos fly into the cloud (iOS `showFreed`).
    val shownBytes = remember { Animatable(0f) }
    var burst by remember { mutableStateOf<CatchingBurst?>(null) }
    var previews by remember { mutableStateOf<Map<String, Any>>(emptyMap()) }
    val reduceMotion = rememberReduceMotion()
    var reload by remember { mutableIntStateOf(0) }

    LaunchedEffect(reload) {
        val found = service.candidates()
        candidates = found
        val now = System.currentTimeMillis()
        verified = found.filter { FreeUpSpace.isFreshlyVerified(it, now) }
    }

    val trash = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { r ->
        val asked = removing
        val pictures = previews
        removing = emptyList()
        previews = emptyMap()
        if (r.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult
        scope.launch {
            val ids = asked.mapNotNull { it.localId }
            val still = withContext(Dispatchers.IO) { service.stillOnPhone(ids) }
            val gone = asked.filter { it.localId !in still }
            AppLog.info("Freed up space: moved ${gone.size} items to the phone's trash")
            val bytes = FreeUpSpace.bytes(gone)
            freed = gone.size to bytes
            if (gone.isNotEmpty()) haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            burst = gone.mapNotNull { it.localId?.let(pictures::get) }.takeIf { it.isNotEmpty() }?.let(::CatchingBurst)
            reload++
            shownBytes.snapTo(0f)
            shownBytes.animateTo(bytes.toFloat(), tween(700, easing = { 1 - (1 - it) * (1 - it) * (1 - it) }))
        }
    }

    fun remove() = scope.launch {
        try {
            val safe = service.safeToRemove(verified)
            if (safe.isEmpty()) { Messages.show(Messages.Style.Info, "Nothing to remove", "Check what's safe to remove again."); return@launch }
            if (Build.VERSION.SDK_INT < 30) { Messages.show(Messages.Style.Info, "Removing needs Android 11 or later"); return@launch }
            val uris = withContext(Dispatchers.IO) { service.files(safe).map { it.uri } }
            removing = safe
            // Small pictures of the first few, loaded now: once in the trash, the phone no longer hands them out.
            if (!reduceMotion) previews = withContext(Dispatchers.IO) {
                val loader = SingletonImageLoader.get(context)
                safe.take(8).mapNotNull { item ->
                    val id = item.localId ?: return@mapNotNull null
                    val uri = app.photos.uris(listOf(id)).firstOrNull() ?: return@mapNotNull null
                    val image = (loader.execute(ImageRequest.Builder(context).data(PhoneThumbnail(uri)).size(120).build()) as? SuccessResult)?.image
                    image?.let { id to it.toBitmap() }
                }.toMap()
            }
            trash.launch(IntentSenderRequest.Builder(MediaStore.createTrashRequest(context.contentResolver, uris, true).intentSender).build())
        } catch (e: IllegalStateException) {
            Messages.show(Messages.Style.Failure, "Couldn't check your library", e.message)
        }
    }

    Scaffold(modifier, topBar = {
        TopAppBar(title = { Text("Free up space") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } })
    }) { padding ->
        val list = candidates
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            item("intro") {
                Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    val f = freed
                    CatchingMark(if (f == null) CatchingStatus.Idle else CatchingStatus.Complete, width = 84.dp, burst = burst, modifier = Modifier.padding(top = 6.dp))
                    if (f != null) {
                        Text(
                            Formatter.formatShortFileSize(context, shownBytes.value.toLong()),
                            style = MaterialTheme.typography.headlineLarge.copy(fontWeight = FontWeight.Bold, fontFeatureSettings = "tnum"),
                            color = MaterialTheme.colorScheme.primary, textAlign = TextAlign.Center,
                            modifier = Modifier.semantics { contentDescription = "Freed ${Formatter.formatShortFileSize(context, f.second)}" },
                        )
                    } else {
                        Text("Free up space on this phone", style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                    }
                    Text(
                        if (f != null) "Freed from ${"%,d".format(f.first)} item${if (f.first == 1) "" else "s"}. They're still in your Telegram library and in Lelvo. Empty the trash in your gallery app to get the space back now."
                        else "Remove photos and videos from this phone that are already safely backed up, to get storage back. They stay in Lelvo, and you can save any of them back anytime.",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
                    )
                }
            }
            item("counts") {
                HorizontalDivider()
                ValueRow("Backed up and on this phone", list?.size?.let { "%,d".format(it) } ?: "…")
                ValueRow("Checked, safe to remove", "%,d".format(verified.size))
                ValueRow("Space you can free", Formatter.formatShortFileSize(context, FreeUpSpace.bytes(verified)))
                Note("Before anything is offered, Lelvo checks in Telegram that every part of it is really there. Items not fully backed up, or changed after their backup, are never offered.")
            }
            item("actions") {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (checking != null && list != null) {
                        LinearProgressIndicator(progress = { checked.toFloat() / maxOf(1, list.size) }, modifier = Modifier.fillMaxWidth())
                        Text("Checking $checked of ${list.size}…", style = MaterialTheme.typography.bodySmall)
                        OutlinedButton(onClick = { checking?.cancel(); checking = null }, modifier = Modifier.fillMaxWidth()) { Text("Stop") }
                    } else {
                        OutlinedButton(
                            onClick = {
                                checking = scope.launch {
                                    val all = list.orEmpty()
                                    checked = 0
                                    val ok = ArrayList<LibraryItem>()
                                    for (item in all) {
                                        if (service.verify(item)) ok += item
                                        checked++
                                        verified = ok.toList()
                                    }
                                    checking = null
                                    reload++
                                }
                            },
                            enabled = !list.isNullOrEmpty(), modifier = Modifier.fillMaxWidth(),
                        ) { Text("Check what's safe to remove") }
                        if (verified.isNotEmpty()) Button(
                            onClick = { remove() }, modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                        ) { Text("Remove ${"%,d".format(verified.size)} item${if (verified.size == 1) "" else "s"} (${Formatter.formatShortFileSize(context, FreeUpSpace.bytes(verified))})") }
                    }
                }
                Note("Android asks you to confirm. Removed items go to the trash on this phone for 30 days; empty it to get the space back right away. They stay in Lelvo as cloud items.")
            }
            if (verified.isNotEmpty()) {
                item("safeHeader") { Header("Safe to remove") }
                items(verified.take(200), key = { it.id }) { item ->
                    ListItem(headlineContent = { Text(item.filename, maxLines = 1) },
                        trailingContent = { Text(Formatter.formatShortFileSize(context, item.fileSize + (item.pairedVideoSize ?: 0))) })
                }
                if (verified.size > 200) item("more") { Note("…and ${verified.size - 200} more") }
            }
        }
    }
}

@Composable
internal fun ValueRow(title: String, value: String) {
    ListItem(headlineContent = { Text(title) }, trailingContent = { Text(value, style = MaterialTheme.typography.bodyLarge) })
}

@Composable
internal fun Note(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
}

@Composable
internal fun Header(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
}
