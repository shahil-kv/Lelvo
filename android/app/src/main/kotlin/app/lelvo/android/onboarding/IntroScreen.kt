package app.lelvo.android.onboarding

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lelvo.android.R
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.android.ui.theme.rememberReduceMotion
import app.lelvo.data.media.PhotoAccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

private const val FAQ = "https://github.com/shahil-kv/Lelvo/blob/main/docs/FAQ.md"
private const val PAGES = 6

/**
 * The first-run story before Telegram sign-in (iOS `IntroView`): what Lelvo is, the problem it solves, what you get,
 * who can see your photos, honest answers, and your own library in numbers. Nothing here talks to Telegram.
 * A swipeable pager with a filled button, like Google Photos' and Files by Google's first run.
 */
@Composable
fun IntroScreen(photos: PhotoAccess, start: Int, onPage: (Int) -> Unit, onFinish: () -> Unit) {
    val pager = rememberPagerState(initialPage = start) { PAGES }
    val scope = rememberCoroutineScope()
    val reduce = rememberReduceMotion()
    var status by remember { mutableStateOf(photos.status()) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { status = photos.markAsked() }
    LaunchedEffect(pager.currentPage) { onPage(pager.currentPage) }
    val go: (Int) -> Unit = { p -> scope.launch { if (reduce) pager.scrollToPage(p) else pager.animateScrollToPage(p) } }
    BackHandler(enabled = pager.currentPage > 0) { go(pager.currentPage - 1) }

    val page = pager.currentPage
    val title = when {
        page == 0 -> "Get started"
        page == 4 -> "Continue to Lelvo"
        page == 5 && status == PhotoAccess.Status.NotAsked -> "Allow access to photos"
        page == 5 -> "Continue with Telegram"
        else -> "Continue"
    }
    // A Surface, not a plain Box, so text and icons take the theme's content colour in dark mode.
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { Box(Modifier.fillMaxSize()) {
        // The hook page has the photo wall behind it; the rest a soft accent glow from the top, like iOS.
        val glow by animateFloatAsState(if (page == 0) 0f else 1f, tween(600), label = "glow")
        // Drawn only while it can be seen: it redraws every frame, which would slow the other pages' animations.
        if (glow < 1f) PhotoWallBackground(Modifier.fillMaxSize().graphicsLayer { alpha = 1f - glow }, reduce, paused = page != 0)
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = glow }.background(
            Brush.radialGradient(listOf(Lelvo.colors.accent.copy(alpha = 0.18f), Color.Transparent), center = Offset(540f, 0f), radius = 1300f)))
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            Box(Modifier.height(56.dp).padding(horizontal = 4.dp), contentAlignment = Alignment.CenterStart) {
                if (page > 0) IconButton(onClick = { go(page - 1) }) {
                    Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back")
                }
            }
            HorizontalPager(pager, Modifier.weight(1f).fillMaxWidth(), beyondViewportPageCount = 1) { p ->
                Box(Modifier.fillMaxSize().widthIn(max = 560.dp), contentAlignment = Alignment.TopCenter) {
                    when (p) {
                        0 -> HookPage(reduce)
                        1 -> PainPage(active = page == 1, reduce)
                        2 -> FeaturesPage(active = page == 2, reduce)
                        3 -> PrivacyPage(reduce)
                        4 -> QuestionsPage()
                        else -> NumbersPage(photos, status)
                    }
                }
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Dots(page)
                Button(
                    onClick = {
                        when {
                            page < PAGES - 1 -> go(page + 1)
                            status == PhotoAccess.Status.NotAsked -> ask.launch(photos.permissions)
                            else -> onFinish()
                        }
                    },
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                ) { Text(title, style = MaterialTheme.typography.titleMedium) }
                // Photos access can wait: sign-in and the cloud library work without it.
                if (page == PAGES - 1 && status == PhotoAccess.Status.NotAsked) TextButton(onClick = onFinish) { Text("Not now") }
                if (page == 0) {
                    // Telegram API terms 2.2 ask for this to be prominent in the intro, so it can't be small tertiary text.
                    Text("Lelvo uses the Telegram API and is part of the Telegram ecosystem. Not affiliated with Telegram.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                }
            }
        }
    }
} }

@Composable
private fun Dots(page: Int) {
    Row(horizontalArrangement = Arrangement.spacedBy(7.dp), modifier = Modifier.clearAndSetSemantics { contentDescription = "Page ${page + 1} of $PAGES" }) {
        repeat(PAGES) { i ->
            val w by animateDpAsState(if (i == page) 20.dp else 7.dp, spring(stiffness = Spring.StiffnessMediumLow), label = "dot")
            val c by animateColorAsState(if (i == page) Lelvo.colors.accent else Lelvo.colors.fillStrong, label = "dotColor")
            Box(Modifier.size(w, 7.dp).clip(CircleShape).background(c))
        }
    }
}

/** Art on top, then a big title and a short line. Scrolls on small screens and with large text. */
@Composable
private fun IntroPage(title: String, subtitle: String, art: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        art()
        Spacer(Modifier.height(10.dp))
        Title(title)
        Text(subtitle, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Title(text: String) = Text(text, style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold),
    modifier = Modifier.semantics { heading() })

// 1. Hook

@Composable
private fun HookPage(reduce: Boolean) {
    val shown = remember { Animatable(if (reduce) 1f else 0f) }
    LaunchedEffect(Unit) { if (!reduce) { delay(250); shown.animateTo(1f, spring(dampingRatio = 0.75f, stiffness = 60f)) } }
    val accent = Lelvo.colors.accent
    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp).padding(bottom = 8.dp)
        .graphicsLayer { alpha = shown.value; translationY = (1f - shown.value) * 28.dp.toPx() },
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.Bottom)) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f)) {
            Row(Modifier.padding(horizontal = 12.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(painterResource(R.drawable.ic_lock), null, Modifier.size(14.dp))
                Spacer(Modifier.width(6.dp))
                Text("Private · Open source · No servers", style = MaterialTheme.typography.labelLarge)
            }
        }
        Text(
            buildAnnotatedString {
                append("Your photos.\n")
                withStyle(SpanStyle(brush = Brush.linearGradient(listOf(accent, Color(0xFFD4A8FF))))) { append("Only yours.") }
            },
            style = MaterialTheme.typography.displayMedium.copy(fontWeight = FontWeight.Bold, lineHeight = 50.sp, letterSpacing = (-0.8).sp),
            modifier = Modifier.semantics { heading() },
        )
        Text("Every original, locked on your phone and kept in your own Telegram account. No servers of ours.",
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Normal), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * Full-bleed, slowly drifting columns of the demo photos, like a library scrolling by. Green check badges pop onto
 * photos as they pass: everything getting backed up. Fades into the background where the text sits.
 */
@Composable
private fun PhotoWallBackground(modifier: Modifier, reduce: Boolean, paused: Boolean) {
    val context = LocalContext.current
    val images by produceState(emptyList<ImageBitmap>()) {
        value = withContext(Dispatchers.IO) {
            (1..24).mapNotNull { n ->
                runCatching {
                    context.assets.open("photo%02d.jpg".format(n)).use { s ->
                        BitmapFactory.decodeStream(s, null, BitmapFactory.Options().apply { inSampleSize = 8 })?.asImageBitmap()
                    }
                }.getOrNull()
            }
        }
    }
    // Kept across a pause, so the wall carries on from where it stopped rather than jumping.
    var time by rememberSaveable { mutableLongStateOf(0L) }
    if (!reduce && !paused) LaunchedEffect(Unit) {
        val start = withFrameNanos { it } - time
        while (true) withFrameNanos { time = it - start }
    }
    val palettes = remember {
        listOf(0xFFFF9500 to 0xFFFF2D55, 0xFF30B0C7 to 0xFF007AFF, 0xFF34C759 to 0xFF30B0C7, 0xFFAF52DE to 0xFF5856D6,
            0xFFFFCC00 to 0xFFFF9500, 0xFFFF2D55 to 0xFFFF3B30).map { (a, b) -> listOf(Color(a), Color(b)) }
    }
    val bg = MaterialTheme.colorScheme.background
    val green = Lelvo.colors.green
    Canvas(modifier) {
        val t = time / 1e9
        val spacing = 10.dp.toPx()
        val wall = size.width * 1.4f
        val w = (wall - spacing * 3) / 4
        val ratios = floatArrayOf(1.3f, 1f, 1.45f, 1.1f, 1.25f, 0.95f, 1.4f, 1.15f)
        val speeds = doubleArrayOf(16.0, 24.0, 13.0, 20.0)
        val radius = CornerRadius(18.dp.toPx())
        val badge = 11.dp.toPx()
        rotate(-9f, pivot = Offset(size.width / 2, size.height / 2)) {
            for (col in 0 until 4) {
                val heights = FloatArray(8) { w * ratios[(it + col * 3) % 8] }
                val loop = heights.sum() + spacing * 8
                val moved = ((t * speeds[col] * density / 3) % loop).toFloat()
                // Neighbouring columns drift in opposite directions, which reads as depth.
                var y = (if (col % 2 == 0) -moved else moved - loop) - size.height * 0.12f
                val x = -(wall - size.width) / 2 + col * (w + spacing)
                for (i in 0 until 16) {
                    val h = heights[i % 8]
                    val n = i % 8 + col * 8
                    if (y + h > -200 && y < size.height + 200) {
                        val tile = Path().apply { addRoundRect(androidx.compose.ui.geometry.RoundRect(x, y, x + w, y + h, radius)) }
                        clipPath(tile) {
                            val img = images.getOrNull(n % max(1, images.size))
                            if (img != null) {
                                val scale = max(w / img.width, h / img.height)
                                val dw = img.width * scale; val dh = img.height * scale
                                drawImage(img, dstOffset = IntOffset((x + (w - dw) / 2).toInt(), (y + (h - dh) / 2).toInt()),
                                    dstSize = androidx.compose.ui.unit.IntSize(dw.toInt(), dh.toInt()))
                            } else drawRect(Brush.linearGradient(palettes[n % palettes.size], Offset(x, y), Offset(x + w, y + h)), Offset(x, y), Size(w, h))
                        }
                        // Each photo gets its badge at its own moment, pops in, stays a while, then the cycle repeats.
                        val phase = ((t + n * 0.73) / 7) % 1.0
                        val k = min(1.0, max(0.0, (phase - 0.35) * 8))
                        val pop = if (reduce) 1.0 else if (k < 1) k * (1 + 0.35 * sin(k * PI)) else 1.0
                        if (reduce || phase > 0.35) {
                            val c = Offset(x + w - badge - 8.dp.toPx(), y + badge + 8.dp.toPx())
                            val r = (badge * pop).toFloat()
                            drawCircle(Color.Black.copy(alpha = 0.25f), r, c + Offset(0f, 2.dp.toPx()))
                            drawCircle(green, r, c)
                            drawPath(Path().apply { moveTo(c.x - 0.42f * r, c.y); lineTo(c.x - 0.1f * r, c.y + 0.32f * r); lineTo(c.x + 0.45f * r, c.y - 0.32f * r) },
                                Color.White, style = Stroke(0.2f * r, cap = StrokeCap.Round))
                        }
                    }
                    y += h + spacing
                }
            }
        }
        // Fades the wall into the page where the text sits, and keeps the status bar readable.
        drawRect(Brush.verticalGradient(0.3f to Color.Transparent, 0.48f to bg.copy(alpha = 0.7f), 0.6f to bg, startY = 0f, endY = size.height))
        drawRect(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.45f), Color.Transparent), endY = 120.dp.toPx()))
    }
}

// 2. Pain

@Composable
private fun PainPage(active: Boolean, reduce: Boolean) {
    val full = remember { Animatable(0f) }
    val mine = remember { Animatable(0f) }
    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        if (reduce) { full.snapTo(1f); mine.snapTo(1f); return@LaunchedEffect }
        launch { delay(150); full.animateTo(1f, tween(700)) }
        delay(850); mine.animateTo(1f, spring(dampingRatio = 0.8f, stiffness = 120f))
    }
    IntroPage("Storage full again? Keep every photo without a monthly bill.",
        "Your library uses an account you already have, so there's no storage plan to buy.") {
        Column(Modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Meter("Cloud storage", "15 of 15 GB", full.value, Lelvo.colors.red) {
                Column(Modifier.graphicsLayer { alpha = full.value }) {
                    Text("Storage full. Backups have stopped.", style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold), color = Lelvo.colors.red)
                    Text("Upgrade for a monthly fee, or start deleting.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Box(Modifier.graphicsLayer { alpha = mine.value; translationY = (1 - mine.value) * 12.dp.toPx() }) {
                Meter("Your Lelvo library", "Unlimited storage", 0.18f * mine.value, Lelvo.colors.accent) {
                    Text("Every original, full quality, nothing compressed.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun Meter(title: String, value: String, fill: Float, color: Color, below: @Composable () -> Unit) {
    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text(value, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Box(Modifier.fillMaxWidth().height(10.dp).clip(CircleShape).background(Lelvo.colors.fillStrong)) {
                Box(Modifier.fillMaxWidth(fill.coerceIn(0f, 1f)).height(10.dp).clip(CircleShape).background(color))
            }
            below()
        }
    }
}

// 3. What you get

private class Feature(val icon: Int, val title: String, val detail: String)

private val features = listOf(
    Feature(R.drawable.ic_cloud_upload, "Every original, backed up", "Photos and videos at full quality"),
    Feature(R.drawable.ic_storage, "Free up space", "Remove what's safely backed up"),
    Feature(R.drawable.ic_play, "Videos play at once", "Streamed, no full download"),
    Feature(R.drawable.ic_search, "Search your photos", "Places, dates, text and things"),
    Feature(R.drawable.ic_auto_awesome, "Memories and collections", "Your best days, picked for you"),
    Feature(R.drawable.ic_map, "Your photos on a map", "Every trip, every place"),
)

/** Every feature in plain words, most loved first, lit up one at a time. Tapping one shows it straight away. */
@Composable
private fun FeaturesPage(active: Boolean, reduce: Boolean) {
    var lit by rememberSaveable { mutableIntStateOf(0) }
    var pausedUntil by remember { mutableLongStateOf(0L) }
    LaunchedEffect(active, reduce) {
        if (!active || reduce) return@LaunchedEffect
        while (true) {
            delay(2600)
            if (System.currentTimeMillis() >= pausedUntil) lit = (lit + 1) % features.size
        }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // Android screenshots come with the Photos and Search tabs; until then the feature's own symbol, large.
        Box(Modifier.fillMaxWidth().height(170.dp).clip(RoundedCornerShape(28.dp))
            .background(Brush.linearGradient(listOf(Lelvo.colors.accentSoft, Lelvo.colors.accent.copy(alpha = 0.35f)))),
            contentAlignment = Alignment.Center) {
            Crossfade(lit, animationSpec = tween(450), label = "feature") { i ->
                Icon(painterResource(features[i].icon), null, Modifier.size(84.dp), tint = Lelvo.colors.accent)
            }
        }
        Title("Everything in one app")
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            features.forEachIndexed { i, f ->
                val on = i == lit
                val bg by animateColorAsState(if (on) Lelvo.colors.accentSoft else Color.Transparent, tween(350), label = "row")
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(bg)
                    .clickable { pausedUntil = System.currentTimeMillis() + 6000; lit = i }
                    .semantics(mergeDescendants = true) { selected = on }
                    .padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(painterResource(f.icon), null, Modifier.size(22.dp), tint = if (on) Lelvo.colors.accent else MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(14.dp))
                    Column {
                        Text(f.title, style = MaterialTheme.typography.titleSmall)
                        Text(f.detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

// 4. Privacy

@Composable
private fun PrivacyPage(reduce: Boolean) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Flow(reduce)
        Title("Only you can open them")
        Text("Every photo is locked on your phone before it leaves. You open your library with your passphrase.",
            style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        // Showing exactly what Telegram stores says more than any sentence about it.
        TelegramPreview()
        Row(verticalAlignment = Alignment.Top) {
            Icon(painterResource(R.drawable.ic_warning), null, Modifier.size(20.dp), tint = Lelvo.colors.orange)
            Spacer(Modifier.width(10.dp))
            Text("If you lose your passphrase and your recovery key, nobody can get your photos back. Not us, not Telegram.",
                style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/** Your phone, an empty crossed-out box where a company's server would be, then your Telegram. */
@Composable
private fun Flow(reduce: Boolean) {
    var p by remember { mutableStateOf(0.5f) }
    if (!reduce) LaunchedEffect(Unit) {
        val start = withFrameNanos { it }
        while (true) withFrameNanos { p = (((it - start) / 1e9 / 2.6) % 1.0).toFloat() }
    }
    val accent = Lelvo.colors.accent
    val red = Lelvo.colors.red
    Box(Modifier.fillMaxWidth().height(110.dp).clearAndSetSemantics {
        contentDescription = "Photos go from your phone straight to your Telegram. Lelvo has no servers."
    }) {
        Row(Modifier.fillMaxWidth().padding(top = 40.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Top) {
            Node(R.drawable.ic_phone, "Your phone")
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Canvas(Modifier.size(44.dp)) {
                    drawRoundRect(red, cornerRadius = CornerRadius(15.dp.toPx()),
                        style = Stroke(2.dp.toPx(), pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))))
                }
                Text("Our servers: none", style = MaterialTheme.typography.labelMedium, color = red)
            }
            Node(R.drawable.ic_send, "Your Telegram")
        }
        // Your photo arcs over the empty box, straight to your Telegram.
        Canvas(Modifier.fillMaxSize()) {
            val x = size.width * 0.1f + size.width * 0.8f * p
            val y = 61.dp.toPx() - 52.dp.toPx() * sin(p * PI).toFloat()
            drawRoundRect(accent, Offset(x - 5.5f.dp.toPx(), y - 5.5f.dp.toPx()), Size(11.dp.toPx(), 11.dp.toPx()), CornerRadius(3.dp.toPx()))
        }
    }
}

@Composable
private fun Node(icon: Int, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.width(96.dp)) {
        Icon(painterResource(icon), null, Modifier.size(28.dp), tint = Lelvo.colors.accent)
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** What the library channel in Telegram holds for one photo: an unreadable `.cge` file, like the real channel. */
@Composable
private fun TelegramPreview() {
    // Real-looking CGFE caption text, as the channel shows it. Not a real key or file.
    val cipher = "CG1E:mvOrfa5vpbolKpiUJQy4f5UvnWUk7KLmQnt2Fdpe+zHb5H4B85PgZEbUzr/wkrJHgjrFrltUd62No9R4NfniT+4ZXYwhHBSsg+oLXC+n57UghHwPElFF3hO1hWhmFehMrWh8oqE1oGRP"
    Column(Modifier.clearAndSetSemantics { contentDescription = "In your Telegram, each photo is an unreadable file that only you can open." },
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("What your Telegram stores for one photo", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        // Telegram's own dark message bubble, in light mode too: it shows what Telegram shows.
        Column(Modifier.widthIn(max = 320.dp).clip(RoundedCornerShape(16.dp, 16.dp, 16.dp, 4.dp)).background(Color(0xFF29364A)).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(36.dp).clip(CircleShape).background(Color(0xFF4F8EDB)), contentAlignment = Alignment.Center) {
                    Icon(painterResource(R.drawable.ic_file_lock), null, Modifier.size(18.dp), tint = Color.White)
                }
                Spacer(Modifier.width(10.dp))
                Column {
                    Text("094f94fb-2064-49c6.o.cge", style = MaterialTheme.typography.labelLarge, color = Color.White, maxLines = 1)
                    Text("2.8 MB · nobody can open it but you", style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.6f))
                }
            }
            Text(cipher, fontFamily = FontFamily.Monospace, fontSize = 10.sp, lineHeight = 13.sp, color = Color.White.copy(alpha = 0.55f), maxLines = 3)
        }
    }
}

// 5. Questions

private class Question(val icon: Int, val question: String, val answer: String)

// Keep these in line with docs/FAQ.md and the iPhone's. **bold** marks what a skim should catch.
private val questions = listOf(
    Question(R.drawable.ic_visibility, "Can Lelvo see my photos?",
        "**No. Lelvo has no servers.** The app talks only to Telegram, as you, like the official Telegram apps. **We have no way to see your library or your account.**"),
    Question(R.drawable.ic_send, "Can Telegram see my photos?",
        "**No. Lelvo locks every file on your phone before upload**, so Telegram stores only files it can't open."),
    Question(R.drawable.ic_delete, "Will Lelvo delete photos from my phone?",
        "**Only when you choose Free Up Space**, and only items Lelvo has just checked are complete in Telegram. **You confirm every deletion**, and they stay in your phone's trash for 30 days."),
    Question(R.drawable.ic_warning, "What if I lose my Telegram account?",
        "**Your library goes with it.** Telegram deletes accounts unused for 18 months by default; **Lelvo can raise this to 2 years**. For a second copy, **Download a copy of your library** saves every original to a drive or folder."),
    Question(R.drawable.ic_storage, "What does storage cost?",
        "**Lelvo doesn't charge for storage.** Your library uses your own Telegram account, under Telegram's terms, with files up to 2 GB each, or 4 GB with Premium. Lelvo splits bigger videos automatically. **Telegram can change its terms.**"),
    Question(R.drawable.ic_key, "What if I forget my passphrase?",
        "Your **recovery key** opens the library and lets you set a new passphrase. **If you lose both, nobody can open your photos, including us.** Keep them in a password manager."),
    Question(R.drawable.ic_verified_user, "Does this follow Telegram's rules?",
        "**Lelvo follows Telegram's API terms**, with its own app ID. It's an independent project, **not made, reviewed or approved by Telegram**."),
    Question(R.drawable.ic_code, "What if Lelvo stops being developed?",
        "**Your photos stay in your Telegram** as normal files, in a documented format. The code is open source, so anyone can keep it going, and **you can download everything at any time**."),
)

/** Straight answers before anyone trusts us with their photos. The four that matter most show first. */
@Composable
private fun QuestionsPage() {
    var open by rememberSaveable { mutableIntStateOf(-1) }
    var all by rememberSaveable { mutableStateOf(false) }
    val uri = LocalUriHandler.current
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(painterResource(R.drawable.ic_verified_user), null, Modifier.size(34.dp), tint = Lelvo.colors.accent)
        Title("Before you trust us with your photos")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Badge(R.drawable.ic_code, "Open source", Modifier.weight(1f))
            Badge(R.drawable.ic_dns, "No servers", Modifier.weight(1f))
            Badge(R.drawable.ic_visibility_off, "No tracking", Modifier.weight(1f))
        }
        Text("Straight answers, including the parts that aren't in our favour.", style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Column {
            questions.forEachIndexed { i, q ->
                AnimatedVisibility(all || i < 4, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                    Column {
                        if (i > 0) HorizontalDivider(Modifier.padding(start = 40.dp))
                        QuestionRow(q, open == i) { open = if (open == i) -1 else i }
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (!all) TextButton(onClick = { all = true }) {
                Text("${questions.size - 4} more questions")
                Icon(painterResource(R.drawable.ic_expand_more), null, Modifier.size(18.dp))
            }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { uri.openUri(FAQ) }) { Text("Full FAQ") }
        }
    }
}

@Composable
private fun Badge(icon: Int, text: String, modifier: Modifier) {
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = modifier) {
        Column(Modifier.padding(vertical = 12.dp).semantics(mergeDescendants = true) {}, horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(painterResource(icon), null, Modifier.size(20.dp), tint = Lelvo.colors.accent)
            Text(text, style = MaterialTheme.typography.labelMedium, maxLines = 1)
        }
    }
}

@Composable
private fun QuestionRow(q: Question, isOpen: Boolean, toggle: () -> Unit) {
    val turn by animateFloatAsState(if (isOpen) 180f else 0f, label = "chevron")
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val strong = MaterialTheme.colorScheme.onSurface
    Column {
        Row(Modifier.fillMaxWidth().clickable(onClick = toggle)
            .semantics(mergeDescendants = true) { stateDescription = if (isOpen) "Expanded" else "Collapsed" }
            .padding(vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(q.icon), null, Modifier.size(22.dp), tint = Lelvo.colors.accent)
            Spacer(Modifier.width(18.dp))
            Text(q.question, style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium), modifier = Modifier.weight(1f))
            Icon(painterResource(R.drawable.ic_expand_more), null, Modifier.size(22.dp).rotate(turn), tint = dim)
        }
        AnimatedVisibility(isOpen, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
            // The key points in full colour, the rest dimmer, so a skim catches what matters.
            Text(boldAnswer(q.answer, strong, dim), style = MaterialTheme.typography.bodyMedium.copy(lineHeight = 21.sp),
                modifier = Modifier.padding(start = 40.dp, bottom = 14.dp))
        }
    }
}

private fun boldAnswer(markdown: String, strong: Color, dim: Color) = buildAnnotatedString {
    markdown.split("**").forEachIndexed { i, part ->
        if (i % 2 == 1) withStyle(SpanStyle(color = strong, fontWeight = FontWeight.SemiBold)) { append(part) }
        else withStyle(SpanStyle(color = dim)) { append(part) }
    }
}

// 6. Your numbers

@Composable
private fun NumbersPage(photos: PhotoAccess, status: PhotoAccess.Status) {
    val context = LocalContext.current
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        when (status) {
            PhotoAccess.Status.NotAsked -> {
                Icon(painterResource(R.drawable.ic_photo_library), null, Modifier.size(38.dp), tint = Lelvo.colors.accent)
                Title("See your library in numbers")
                Text("Lelvo needs access to photos to back them up. They're counted here on this phone, and go only to your own library.",
                    style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row {
                    Icon(painterResource(R.drawable.ic_info), null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(10.dp))
                    Text("Choose Allow all so every photo is backed up. You can change it in Settings at any time.", style = MaterialTheme.typography.bodyMedium)
                }
            }
            PhotoAccess.Status.Denied -> {
                Icon(painterResource(R.drawable.ic_photo_library), null, Modifier.size(38.dp), tint = Lelvo.colors.orange)
                Title("No access to photos")
                Text("You can still sign in and browse your Telegram library. To back up this phone, allow access in Settings.",
                    style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { context.startActivity(appSettings(context.packageName)) }, Modifier.offset(x = (-12).dp)) { Text("Open Settings") }
                NextStep()
            }
            else -> Numbers(photos, partial = status == PhotoAccess.Status.Partial)
        }
    }
}

private fun appSettings(pkg: String) =
    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", pkg, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

@Composable
private fun Numbers(photos: PhotoAccess, partial: Boolean) {
    val stats by produceState<PhotoAccess.Stats?>(null) { value = photos.stats() }
    val recent by produceState(emptyList<Bitmap>()) { value = photos.recent(5, 320) }
    // The user's own newest photos, fanned out: the moment this stops being a demo.
    PhotoFan(recent)
    val count = remember { Animatable(0f) }
    LaunchedEffect(stats) { stats?.let { count.animateTo(it.items.toFloat(), tween(1200)) } }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("%,d".format(count.value.toInt()), style = MaterialTheme.typography.displayLarge.copy(fontWeight = FontWeight.Bold))
        Text(if (partial) "photos and videos you've shared with Lelvo" else "photos and videos on this phone",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Tile(stats?.let { size(it.bytes) } ?: "…", "to back up", MaterialTheme.colorScheme.onSurface, Modifier.weight(1f))
        Tile(stats?.let { size(it.free) } ?: "…", "free on this phone",
            if ((stats?.free ?: Long.MAX_VALUE) < 10_000_000_000) Lelvo.colors.red else MaterialTheme.colorScheme.onSurface, Modifier.weight(1f))
    }
    Text(stats?.let { "Keep all ${size(it.bytes)} safe." } ?: "Measuring your library…", style = MaterialTheme.typography.titleMedium)
    Text("Counted on this phone. Nothing has been uploaded yet.", style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
    NextStep()
}

@Composable
private fun Tile(value: String, label: String, tint: Color, modifier: Modifier) {
    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = modifier) {
        Column(Modifier.padding(vertical = 14.dp).semantics(mergeDescendants = true) {}, horizontalAlignment = Alignment.CenterHorizontally) {
            Text(value, style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold), color = tint)
            Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** What happens after this screen. People expect an SMS; Telegram usually sends the code to its own app instead. */
@Composable
private fun NextStep() {
    Surface(shape = RoundedCornerShape(20.dp), color = Lelvo.colors.accentSoft, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(painterResource(R.drawable.ic_send), null, Modifier.size(18.dp), tint = Lelvo.colors.accent)
                Spacer(Modifier.width(8.dp))
                Text("Next: sign in with Telegram", style = MaterialTheme.typography.titleSmall)
            }
            Text("Your photos are stored in your own Telegram account. Telegram sends the login code to your Telegram app, usually not by SMS.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Up to five photos dealt onto the table one after another, like prints. */
@Composable
private fun PhotoFan(images: List<Bitmap>) {
    if (images.isEmpty()) { Spacer(Modifier.height(8.dp)); return }
    val reduce = rememberReduceMotion()
    BoxWithConstraints(Modifier.fillMaxWidth().height(170.dp), contentAlignment = Alignment.Center) {
        val n = images.size
        images.forEachIndexed { i, bmp ->
            val dealt = remember { Animatable(if (reduce) 1f else 0f) }
            LaunchedEffect(Unit) { if (!reduce) { delay(120L * i); dealt.animateTo(1f, spring(dampingRatio = 0.7f, stiffness = 180f)) } }
            val mid = (n - 1) / 2f
            val angle = (i - mid) * 7f
            val dx = (i - mid) * 44f
            Image(bmp.asImageBitmap(), null, contentScale = ContentScale.Crop,
                modifier = Modifier.size(110.dp, 140.dp)
                    .graphicsLayer {
                        alpha = dealt.value
                        rotationZ = angle * dealt.value
                        translationX = dx.dp.toPx() * dealt.value
                        translationY = (1 - dealt.value) * 60.dp.toPx() + abs(i - mid) * 6.dp.toPx()
                        shadowElevation = 6.dp.toPx(); shape = RoundedCornerShape(14.dp); clip = true
                    }
                    .border(3.dp, Color.White, RoundedCornerShape(14.dp)))
        }
    }
}

/** Decimal units, like the iPhone's `ByteCountFormatter` (.file) and Android's own storage screens. */
private fun size(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> "%.1f GB".format(bytes / 1e9)
    bytes >= 1_000_000 -> "%.0f MB".format(bytes / 1e6)
    else -> "%.0f KB".format(bytes / 1e3)
}
