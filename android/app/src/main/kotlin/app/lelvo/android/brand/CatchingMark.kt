package app.lelvo.android.brand

import android.net.Uri
import android.os.PowerManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.lelvo.android.R
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.android.ui.theme.LelvoMark
import app.lelvo.android.ui.theme.rememberReduceMotion
import coil3.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * The Lelvo mark as the backup's status (iOS `CatchingMark`): each photo that lands flies into the cloud, the cloud
 * gives a little as it catches it, and a check appears when everything is safe. Decorative only: it runs while the
 * screen is on top, at most 4 flights a second, never with Remove animations or Battery Saver; the numbers next to it
 * say the same thing.
 *
 * [landed] is the engine's last upload (the photo's MediaStore id and a counter); a new value sends one photo in.
 * A new [burst] sends its pictures in together, a beat apart (for example the photos just removed from the phone).
 */
@Composable
fun CatchingMark(
    status: CatchingStatus, landed: Pair<String, Int>? = null, photoUri: suspend (String) -> Uri? = { null },
    width: Dp = 96.dp, burst: CatchingBurst? = null, modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val reduceMotion = rememberReduceMotion()
    val scope = rememberCoroutineScope()
    val height = width / LelvoMark.ASPECT_RATIO
    val density = LocalDensity.current
    val wPx = with(density) { width.toPx() }
    val hPx = wPx / LelvoMark.ASPECT_RATIO
    val target = Offset(CLOUD_X * wPx, CLOUD_Y * hPx)

    val camel = remember { PathParser().parsePathString(LelvoMark.CAMEL).toPath() }
    val cloud = remember { PathParser().parsePathString(LelvoMark.CLOUD).toPath() }
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    // iOS `Brand.gradient` (violet to deep). On black the deep end disappears, so dark mode ends on the lighter accent.
    val brush = Brush.linearGradient(listOf(VIOLET, if (dark) Lelvo.colors.accent else DEEP), start = Offset(0f, hPx), end = Offset(wPx, 0f))

    val squashX = remember { Animatable(1f) }
    val squashY = remember { Animatable(1f) }
    val flights = remember { mutableStateListOf<Flight>() }
    var lastFlight by remember { mutableLongStateOf(0L) }
    val dim by animateFloatAsState(if (status == CatchingStatus.Idle) 0.6f else 1f, label = "mark dim")

    fun squashOnce() {
        scope.launch {
            launch { squashX.animateTo(1.07f, tween(90)); squashX.animateTo(1f, spring(Spring.DampingRatioMediumBouncy, Spring.StiffnessMedium)) }
            launch { squashY.animateTo(0.9f, tween(90)); squashY.animateTo(1f, spring(Spring.DampingRatioMediumBouncy, Spring.StiffnessMedium)) }
        }
    }

    fun catchOne() {
        squashOnce()
        haptics.performHapticFeedback(HapticFeedbackType.SegmentFrequentTick)
    }

    LaunchedEffect(landed) {
        val id = landed?.first?.takeIf { it.isNotEmpty() } ?: return@LaunchedEffect
        val now = System.currentTimeMillis()
        val saver = (context.getSystemService(PowerManager::class.java))?.isPowerSaveMode == true
        if (reduceMotion || saver || !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return@LaunchedEffect
        if (now - lastFlight < 250 || flights.size >= 3) return@LaunchedEffect
        val uri = photoUri(id) ?: return@LaunchedEffect
        lastFlight = now
        val side = (Math.random().toFloat() - 0.5f) * 0.7f
        val flight = Flight(PhoneThumbnail(uri), Offset(wPx * (0.5f + side), hPx + with(density) { 70.dp.toPx() }), System.nanoTime())
        flights += flight
        // Not cancelled by the next landing: each flight finishes on its own.
        scope.launch {
            delay(FLIGHT_MS)
            catchOne()
            delay(120)
            flights.remove(flight)
        }
    }

    LaunchedEffect(burst) {
        val models = burst?.models?.take(8)?.takeIf { it.isNotEmpty() } ?: return@LaunchedEffect
        if (reduceMotion || !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return@LaunchedEffect
        val below = with(density) { 84.dp.toPx() }
        models.forEachIndexed { i, model ->
            val spread = if (models.size > 1) i.toFloat() / (models.size - 1) - 0.5f else 0f
            val flight = Flight(model, Offset(wPx * (0.5f + spread * 1.6f), hPx + below), System.nanoTime())
            flights += flight
            scope.launch {
                delay(FLIGHT_MS)
                squashOnce()
                if (i % 3 == 0) haptics.performHapticFeedback(HapticFeedbackType.SegmentFrequentTick)
                delay(120)
                flights.remove(flight)
            }
            delay(85)
        }
    }

    Box(modifier.size(width, height).alpha(dim)) {
        Canvas(Modifier.size(width, height)) {
            val k = size.width / LelvoMark.WIDTH
            withTransform({ scale(k, k, Offset.Zero) }) { drawPath(camel, brush) }
            // The cloud gives from its bottom edge, as on iOS.
            withTransform({
                scale(squashX.value, squashY.value, Offset(target.x, size.height))
                scale(k, k, Offset.Zero)
            }) { drawPath(cloud, brush) }
        }
        for (f in flights) androidx.compose.runtime.key(f.started) { FlightView(f, target) }
        AnimatedVisibility(
            status == CatchingStatus.Complete,
            enter = scaleIn(initialScale = 0.6f) + fadeIn(), exit = scaleOut(targetScale = 0.6f) + fadeOut(),
            modifier = Modifier.offset { IntOffset((wPx * 0.84f - with(density) { 12.dp.toPx() }).roundToInt(), (hPx * 0.62f - with(density) { 12.dp.toPx() }).roundToInt()) },
        ) {
            Icon(
                painterResource(R.drawable.ic_check_circle), contentDescription = null, tint = Lelvo.colors.green,
                modifier = Modifier.size(width * 0.26f).background(MaterialTheme.colorScheme.background, CircleShape).padding(1.dp),
            )
        }
    }
}

enum class CatchingStatus { Working, Complete, Attention, Idle }

/** Pictures for one burst: anything Coil can show (a bitmap loaded before the photos left the phone). A new one plays. */
class CatchingBurst(val models: List<Any>)

private class Flight(val model: Any, val from: Offset, val started: Long)

/** One photo on its way into the cloud: lifts, arcs in, shrinks and fades as it goes in (iOS `FlightView`). */
@Composable
private fun FlightView(flight: Flight, to: Offset) {
    val t = remember { Animatable(0f) }
    LaunchedEffect(Unit) { t.animateTo(1f, tween(FLIGHT_MS.toInt(), easing = LinearEasing)) }
    val density = LocalDensity.current
    val half = with(density) { 20.dp.toPx() }
    val mid = Offset((flight.from.x + to.x) / 2, minOf(flight.from.y, to.y) - with(density) { 26.dp.toPx() })
    AsyncImage(
        flight.model, null, contentScale = ContentScale.Crop,
        modifier = Modifier.size(40.dp).graphicsLayer {
            val ms = t.value * FLIGHT_MS
            // Position: 300 ms up to the top of the arc, 220 ms down into the cloud.
            val p = if (ms < 300) lerp(flight.from, mid, EASE.transform(ms / 300f)) else lerp(mid, to, EASE.transform((ms - 300) / 220f))
            translationX = p.x - half
            translationY = p.y - half
            val s = when {
                ms < 100 -> 1f + 0.05f * EASE.transform(ms / 100f)
                ms < 340 -> 1.05f + (0.55f - 1.05f) * EASE.transform((ms - 100) / 240f)
                else -> 0.55f + (0.12f - 0.55f) * EASE.transform(((ms - 340) / 180f).coerceAtMost(1f))
            }
            scaleX = s; scaleY = s
            alpha = if (ms < 400) 0.95f else 0.95f * (1 - (ms - 400) / 120f).coerceIn(0f, 1f)
            shadowElevation = 6.dp.toPx(); shape = RoundedCornerShape(9.dp); clip = true
        },
    )
}

private fun lerp(a: Offset, b: Offset, f: Float) = Offset(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)

private const val FLIGHT_MS = 520L
private val EASE = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)
private val VIOLET = Color(0xFF5200FF)
private val DEEP = Color(0xFF2A1A41)
/** The middle of the mark's cloud, as a fraction of the mark (iOS `LelvoMark.cloudCenter`). */
private const val CLOUD_X = 0.74f
private const val CLOUD_Y = 0.5f
