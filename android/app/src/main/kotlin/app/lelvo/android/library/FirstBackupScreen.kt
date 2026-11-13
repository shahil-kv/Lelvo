package app.lelvo.android.library

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.brand.markPath
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.android.ui.theme.LelvoMark
import app.lelvo.android.ui.theme.rememberReduceMotion
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.PhoneAsset
import app.lelvo.core.support.AppLog
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import kotlin.math.pow

/**
 * The end of setup with photo access (iOS `FirstBackupView`). A library that already holds photos says "Welcome back"
 * with the count; a new one asks for a first photo to back up and shows it arrive, then "Your library is ready"
 * (iOS `LibraryReadyView`). "Safe" means the engine saw Telegram confirm every part at the right size.
 */
@Composable
fun FirstBackupScreen(app: LelvoApp, onDone: () -> Unit, previewNew: Boolean = false) {
    // `previewNew`: debug preview of a new library's version over a library that already has photos.
    val restored by produceState<Int?>(null) { value = if (previewNew) 0 else withContext(Dispatchers.IO) { app.store.backedUpCount() } }
    val count = restored ?: return
    val returning = count > 0
    val recent by produceState<List<Recent>?>(null) { value = recentPhotos(app, if (returning) 9 else 12) }
    var phase by remember { mutableStateOf<Phase>(Phase.Choosing) }
    var selected by remember { mutableStateOf<String?>(null) }
    var progress by remember { mutableStateOf(0f) }
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val photos = recent
    LaunchedEffect(photos) { if (photos != null && photos.isEmpty() && !returning) phase = Phase.Nothing }
    val finished = phase == Phase.Safe || phase == Phase.AlreadySafe

    fun upload(id: String) = scope.launch {
        phase = Phase.Uploading
        if (photos?.firstOrNull { it.asset.localId == id }?.backedUp == true) {
            phase = Phase.AlreadySafe
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            return@launch
        }
        withContext(Dispatchers.IO) { app.backup.enqueue(listOf(id)) }
        AppLog.info("Onboarding: backing up the chosen first photo")
        app.startBackup(includeNew = false)
        var sawRunning = false
        for (second in 0 until 600) {
            delay(1_000)
            val item = withContext(Dispatchers.IO) { app.store.itemForPhone(id) }
            val activity = app.backup.activity.value
            activity.lanes.values.firstOrNull()?.takeIf { it.total > 0 }?.let { progress = minOf(0.97f, it.sent.toFloat() / it.total) }
            when (item?.status) {
                ItemStatus.BackedUp -> {
                    progress = 1f
                    phase = Phase.Safe
                    haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                    AppLog.info("Onboarding: first photo backed up")
                    return@launch
                }
                ItemStatus.Failed -> { phase = Phase.Stuck(item.lastError ?: "The upload didn't go through. It's listed under Backup › Failed."); return@launch }
                else -> when {
                    activity.isRunning -> { sawRunning = true; if (phase != Phase.Uploading) phase = Phase.Uploading }
                    // The run ended, or never started, with the photo still queued: a setting such as Wi-Fi only holds
                    // it back. The message of an earlier run is ignored for the first few seconds.
                    (sawRunning || second > 8) && activity.message != null -> phase = Phase.Stuck(activity.message!!)
                }
            }
        }
    }

    // A Surface, so text takes the theme's content colour (dark mode drew black titles on black).
    androidx.compose.material3.Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(top = 24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            when {
                returning -> WelcomeBack(count, photos.orEmpty())
                phase == Phase.Choosing -> {
                    Text("Choose your first photo", style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold))
                    Text("Pick one that matters to you. You'll watch it arrive in your library.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    PhotoGrid(photos.orEmpty(), selected) { id -> haptics.performHapticFeedback(HapticFeedbackType.SegmentTick); selected = if (selected == id) null else id }
                }
                finished && photos.orEmpty().count { it.asset.localId != selected } >= 4 ->
                    LibraryReady(photos.orEmpty().filter { it.asset.localId != selected }.map { it.asset }, phase.detail)
                else -> UploadProgress(app, photos.orEmpty().firstOrNull { it.asset.localId == selected }?.asset, phase, progress, finished)
            }
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            val (label, action) = when {
                returning || finished || phase == Phase.Nothing -> "Start using Lelvo" to onDone
                phase == Phase.Choosing -> "Back up this photo" to { selected?.let { upload(it) }; Unit }
                else -> "Continue in the background" to onDone
            }
            Button(
                onClick = action, enabled = phase != Phase.Choosing || returning || selected != null,
                modifier = Modifier.fillMaxWidth().height(52.dp), shape = RoundedCornerShape(26.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Lelvo.colors.accent),
            ) { Text(label, fontWeight = FontWeight.SemiBold) }
            if (!returning && phase == Phase.Choosing) TextButton(onClick = onDone) { Text("Skip for now", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}
}

private sealed class Phase(val title: String, val detail: String) {
    data object Choosing : Phase("Backing up your first photo", "Uploading the original to your library.")
    data object Uploading : Phase("Backing up your first photo", "Uploading the original to your library.")
    data object Safe : Phase("Your first photo is safe.", "Backed up and checked, at full quality. Back up now sends the rest.")
    data object AlreadySafe : Phase("That photo is already safe.", "It's in your library. Back up now sends the rest.")
    data object Nothing : Phase("You're ready.", "There are no photos on this phone yet. New ones can be backed up any time.")
    data class Stuck(val reason: String) : Phase("Your first backup is waiting", "$reason It carries on by itself once that's sorted.")
}

private class Recent(val asset: PhoneAsset, val backedUp: Boolean)

/** The newest photos on this phone, with whether each is already in the library (iOS `RecentPhotos`). */
private suspend fun recentPhotos(app: LelvoApp, limit: Int): List<Recent> = withContext(Dispatchers.IO) {
    val known = app.store.allItems().filter { it.status == ItemStatus.BackedUp }.mapNotNull { it.localId }.toHashSet() + app.store.aliases().keys
    app.photos.assets().filter { !it.isVideo }.take(limit).map { Recent(it, it.localId in known) }
}

@Composable
private fun WelcomeBack(total: Int, photos: List<Recent>) {
    val haptics = LocalHapticFeedback.current
    val reduce = rememberReduceMotion()
    var shown by remember { mutableIntStateOf(if (reduce) total else 0) }
    // 0 → total in about a second and a half, easing out, then a success tap (iOS `countUp`).
    LaunchedEffect(total) {
        if (reduce || total == 0) return@LaunchedEffect
        delay(350)
        for (i in 1..36) {
            val k = i / 36.0
            shown = (total * (1 - (1 - k).pow(3))).toInt()
            delay(40)
        }
        shown = total
        haptics.performHapticFeedback(HapticFeedbackType.Confirm)
    }
    Box(Modifier.size(64.dp).background(Lelvo.colors.green.copy(alpha = 0.15f), RoundedCornerShape(18.dp)), contentAlignment = Alignment.Center) {
        Icon(painterResource(R.drawable.ic_cloud_done), null, Modifier.size(34.dp), tint = Lelvo.colors.green)
    }
    Text("Welcome back", style = MaterialTheme.typography.headlineLarge.copy(fontWeight = FontWeight.Bold))
    Column(Modifier.semantics(mergeDescendants = true) {}) {
        Text(
            NumberFormat.getIntegerInstance().format(shown),
            style = MaterialTheme.typography.displayMedium.copy(fontWeight = FontWeight.ExtraBold), color = Lelvo.colors.accent,
        )
        Text("photos and videos are in your Telegram library", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    PhotoGrid(photos, null, onPick = null)
    Row(verticalAlignment = Alignment.Top) {
        Icon(painterResource(R.drawable.ic_info), null, Modifier.size(18.dp).padding(top = 2.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(8.dp))
        Text(
            "A green cloud means that photo on this phone is already in your library. Back up now sends the rest.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun PhotoGrid(photos: List<Recent>, selected: String?, onPick: ((String) -> Unit)?) {
    val app = LocalContext.current.applicationContext as LelvoApp
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        photos.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                row.forEach { p ->
                    val isSelected = selected == p.asset.localId
                    val scale by animateFloatAsState(if (isSelected) 0.94f else 1f, spring(dampingRatio = Spring.DampingRatioMediumBouncy), label = "pick")
                    Box(
                        Modifier.weight(1f).aspectRatio(1f).scale(scale).clip(RoundedCornerShape(10.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .then(if (isSelected) Modifier.border(BorderStroke(3.dp, Lelvo.colors.accent), RoundedCornerShape(10.dp)) else Modifier)
                            .then(if (onPick != null) Modifier.clickable { onPick(p.asset.localId) } else Modifier)
                            .semantics {
                                contentDescription = if (p.backedUp) "Photo, already backed up" else "Photo"
                                this.selected = isSelected
                            },
                    ) {
                        AsyncImage(app.photos.uri(p.asset), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                        if (p.backedUp) Box(
                            Modifier.align(Alignment.TopEnd).padding(5.dp).size(20.dp).background(Lelvo.colors.green, CircleShape),
                            contentAlignment = Alignment.Center,
                        ) { Icon(painterResource(R.drawable.ic_cloud_done), null, Modifier.size(12.dp), tint = Color.White) }
                        if (isSelected) Icon(
                            painterResource(R.drawable.ic_check_circle), null,
                            Modifier.align(Alignment.BottomEnd).padding(6.dp).size(26.dp).background(Color.White, CircleShape),
                            tint = Lelvo.colors.accent,
                        )
                    }
                }
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun UploadProgress(app: LelvoApp, photo: PhoneAsset?, phase: Phase, progress: Float, finished: Boolean) {
    val shown by animateFloatAsState(if (finished) 1f else progress, tween(400), label = "ring")
    val check by animateFloatAsState(if (finished) 1f else 0f, spring(dampingRatio = 0.45f, stiffness = Spring.StiffnessMediumLow), label = "check")
    val accent = Lelvo.colors.accent
    val green = Lelvo.colors.green
    val track = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f)
    Column(Modifier.fillMaxWidth().padding(top = 30.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(22.dp)) {
        Box(Modifier.size(200.dp).semantics(mergeDescendants = true) { contentDescription = phase.title }, contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                val stroke = Stroke(6.dp.toPx(), cap = StrokeCap.Round)
                drawArc(track, 0f, 360f, false, style = stroke)
                drawArc(if (finished) green else accent, -90f, 360f * shown, false, style = stroke)
            }
            Box(Modifier.size(150.dp).clip(RoundedCornerShape(22.dp)).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
                if (photo != null) AsyncImage(app.photos.uri(photo), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                else Icon(painterResource(R.drawable.ic_photo_library), null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Box(
                Modifier.offset(72.dp, 72.dp).size(50.dp).graphicsLayer { scaleX = 0.6f + 0.4f * check; scaleY = scaleX; alpha = check.coerceIn(0f, 1f) }
                    .background(green, CircleShape).border(3.dp, MaterialTheme.colorScheme.background, CircleShape),
                contentAlignment = Alignment.Center,
            ) { Icon(painterResource(R.drawable.ic_check), null, Modifier.size(24.dp), tint = Color.White) }
        }
        AnimatedContent(phase, label = "phase") { p ->
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(p.title, style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold), textAlign = TextAlign.Center)
                Text(p.detail, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            }
        }
    }
}

/**
 * The end of setup, played once (iOS `LibraryReadyView`, #92): the person's own recent photos fall into a pile, the
 * mark appears under them and pulls them into its cloud, then settles with "Your library is ready". Only transform
 * and opacity move; with animations off it shows the final state at once.
 */
@Composable
private fun LibraryReady(images: List<PhoneAsset>, detail: String) {
    val app = LocalContext.current.applicationContext as LelvoApp
    val haptics = LocalHapticFeedback.current
    val reduce = rememberReduceMotion()
    val photos = images.take(SPOTS.size)
    // Bottom of the pile first, as if the cloud pulls the nearest ones in.
    val pullOrder = remember(photos.size) { photos.indices.sortedByDescending { SPOTS[it].y } }
    var dealt by remember { mutableIntStateOf(if (reduce) photos.size else 0) }
    var markShown by remember { mutableStateOf(reduce) }
    var pulled by remember { mutableIntStateOf(if (reduce) photos.size else 0) }
    var settled by remember { mutableStateOf(reduce) }
    val bounce = remember { Animatable(1f) }
    LaunchedEffect(Unit) {
        if (reduce) return@LaunchedEffect
        for (i in photos.indices) { dealt = i + 1; delay(90) }
        delay(250)
        markShown = true
        delay(450)
        for (i in photos.indices) {
            pulled = i + 1
            launch { bounce.snapTo(0.88f); bounce.animateTo(1f, spring(dampingRatio = 0.4f, stiffness = Spring.StiffnessMedium)) }
            haptics.performHapticFeedback(HapticFeedbackType.SegmentFrequentTick)
            delay(110)
        }
        delay(300)
        settled = true
        haptics.performHapticFeedback(HapticFeedbackType.Confirm)
    }
    val markWidth = 110.dp
    val markRestY = 150.dp
    val inPile = 0.5f
    val markScale by animateFloatAsState(if (!markShown) 0.01f else if (settled) 1f else inPile, spring(dampingRatio = 0.6f), label = "mark")
    val markY by animateFloatAsState(if (settled) -30f else markRestY.value, tween(600, easing = FastOutSlowInEasing), label = "markY")
    val glow by animateFloatAsState(if (settled) 1f else 0f, tween(700), label = "glow")
    val violet = Lelvo.colors.accent
    // iOS shows setup in dark only; here a light screen gets the accent mark over a softer glow, so it stays visible.
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val markColor = if (dark) Color.White else violet
    val glowStops = if (dark) listOf(violet.copy(alpha = 0.7f), violet.copy(alpha = 0.15f), Color.Transparent)
    else listOf(violet.copy(alpha = 0.22f), violet.copy(alpha = 0.07f), Color.Transparent)
    BoxWithConstraints(Modifier.fillMaxWidth().height(440.dp).semantics(mergeDescendants = true) { contentDescription = "Your library is ready. $detail" }, contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(340.dp).offset(y = (-30).dp).graphicsLayer { alpha = glow; scaleX = 0.5f + 0.5f * glow; scaleY = scaleX }) {
            drawCircle(Brush.radialGradient(glowStops, center = center, radius = size.minDimension / 2))
        }
        // Where the cloud of the mark sits while it pulls the photos in.
        val target = Offset(((CLOUD_X - 0.5f) * markWidth.value * inPile), markRestY.value + (CLOUD_Y - 0.5f) * (markWidth.value / LelvoMark.ASPECT_RATIO) * inPile)
        photos.forEachIndexed { i, asset ->
            val spot = SPOTS[i]
            val isPulled = pullOrder.indexOf(i) < pulled
            val inPileNow = i < dealt
            val p by animateFloatAsState(if (isPulled) 1f else 0f, tween(420, easing = FastOutSlowInEasing), label = "pull$i")
            val d by animateFloatAsState(if (inPileNow) 1f else 0f, spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow), label = "deal$i")
            Box(
                Modifier.offset((spot.x + (target.x - spot.x) * p).dp, (spot.y + (target.y - spot.y) * p - 40f * (1 - d)).dp)
                    .size((70 * spot.s).dp, (82 * spot.s).dp)
                    .graphicsLayer {
                        alpha = d * (1 - p * p)
                        rotationZ = spot.r + p * (if (spot.x < 0) 100f else -100f)
                        scaleX = 1f - 0.95f * p; scaleY = scaleX
                        shadowElevation = 10.dp.toPx(); shape = RoundedCornerShape(12.dp); clip = true
                    },
            ) { AsyncImage(app.photos.uri(asset), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        }
        val path = remember { markPath() }
        Canvas(
            Modifier.offset(y = markY.dp).size(markWidth, markWidth / LelvoMark.ASPECT_RATIO)
                .graphicsLayer { scaleX = markScale * (if (settled) 1f else bounce.value + (1 - bounce.value) * -0.6f); scaleY = markScale * bounce.value; alpha = if (markShown) 1f else 0f },
        ) {
            val k = size.width / LelvoMark.WIDTH
            drawContext.transform.scale(k, k, Offset.Zero)
            drawPath(path, markColor)
        }
        Column(
            Modifier.offset(y = (110 + 12 * (1 - glow)).dp).graphicsLayer { alpha = glow }.padding(horizontal = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Your library is ready", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold, fontSize = 28.sp), textAlign = TextAlign.Center)
            Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
}

private class Spot(val x: Float, val y: Float, val r: Float, val s: Float)

/** A loose pile in a 300 × 280 area around the centre: x, y, rotation, size (iOS `LibraryReadyView.spots`). */
private val SPOTS = listOf(
    Spot(-62f, -150f, -7f, 0.85f), Spot(12f, -162f, 6f, 0.8f), Spot(-14f, -110f, -3f, 0.95f), Spot(-74f, -62f, 5f, 1f),
    Spot(30f, -76f, -8f, 1f), Spot(-30f, -20f, 3f, 1.1f), Spot(48f, -6f, 9f, 0.95f), Spot(-68f, 32f, -6f, 0.95f),
    Spot(8f, 40f, 2f, 1.15f), Spot(-36f, 96f, -9f, 0.85f), Spot(46f, 98f, 7f, 0.9f),
)

/** The middle of the mark's cloud, as a fraction of the mark (iOS `LelvoMark.cloudCenter`). */
private const val CLOUD_X = 0.74f
private const val CLOUD_Y = 0.5f
