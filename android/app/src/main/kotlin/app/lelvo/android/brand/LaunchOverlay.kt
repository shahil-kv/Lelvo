package app.lelvo.android.brand

import app.lelvo.android.ui.theme.rememberReduceMotion
import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import app.lelvo.android.ui.theme.LaunchColor
import app.lelvo.android.ui.theme.LelvoMark
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The opening on a cold launch, the iOS `LaunchOverlay` (issue #92). Its first frame is the launch screen (the white
 * mark on Lelvo violet), so there's no jump when the system's splash goes. The mark breathes in once, then you zoom
 * through it into the app, which has been loading underneath the whole time. Under a second, a tap skips it, and with
 * Remove animations on it's only a short pause. Coming back from the background never shows it.
 */
@Composable
fun LaunchHost(play: Boolean, content: @Composable () -> Unit) {
    val reduceMotion = rememberReduceMotion()
    var launching by remember { mutableStateOf(play) }
    // The app eases in from slightly larger as the zoom opens onto it.
    val settle = remember { Animatable(if (play && !reduceMotion) 1.08f else 1f) }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().graphicsLayer { scaleX = settle.value; scaleY = settle.value }) { content() }
        if (launching) {
            LaunchOverlay(
                reduceMotion = reduceMotion,
                onOpening = { settle.animateTo(1f, tween(550, delayMillis = 320, easing = FastOutSlowInEasing)) },
                onSkip = { settle.animateTo(1f, tween(200, easing = LinearOutSlowInEasing)) },
                onFinish = { launching = false },
            )
        }
    }
}

@Composable
private fun LaunchOverlay(
    reduceMotion: Boolean,
    onOpening: suspend () -> Unit,
    onSkip: suspend () -> Unit,
    onFinish: () -> Unit,
) {
    val mark = remember { markPath() }
    // Reused every frame, so the zoom allocates nothing.
    val curtainPath = remember { Path() }
    val zoomedMark = remember { Path() }
    val scale = remember { Animatable(1f) }
    val solid = remember { Animatable(1f) }
    val curtain = remember { Animatable(1f) }
    val scope = rememberCoroutineScope()
    var finished by remember { mutableStateOf(false) }

    fun finish(fast: Boolean) {
        if (finished) return
        finished = true
        scope.launch {
            if (fast) launch { onSkip() }
            curtain.animateTo(0f, tween(if (fast || reduceMotion) 200 else 80, easing = LinearOutSlowInEasing))
            onFinish()
        }
    }

    LaunchedEffect(Unit) {
        // The app's first frames can be slow (services starting, the first grid). The clock starts only once frames
        // flow, so the zoom never begins half-way; until then this frame is the launch screen itself. At most 1.5 s.
        var last = withFrameNanos { it }
        var smooth = 0
        val giveUp = last + 1_500_000_000L
        while (smooth < 3 && last < giveUp) {
            val now = withFrameNanos { it }
            smooth = if (now - last < 34_000_000L) smooth + 1 else 0
            last = now
        }
        if (reduceMotion) {
            delay(150)
            return@LaunchedEffect finish(fast = false)
        }
        launch { onOpening() }
        delay(160)
        scale.animateTo(0.91f, tween(150, easing = FastOutSlowInEasing))
        // Accelerating: slow enough to read the mark, then through it.
        val zoom = async { scale.animateTo(64f, tween(420, easing = CubicBezierEasing(0.6f, 0f, 0.84f, 0.25f))) }
        solid.animateTo(0f, tween(140, easing = LinearOutSlowInEasing))
        zoom.await()
        finish(fast = false)
    }

    Canvas(
        Modifier
            .fillMaxSize()
            .clearAndSetSemantics {}
            .graphicsLayer { alpha = curtain.value }
            .pointerInput(Unit) { detectTapGestures { finish(fast = true) } },
    ) {
        val width = LelvoMark.LAUNCH_WIDTH_DP.dp.toPx()
        val unit = width / LelvoMark.WIDTH
        val height = LelvoMark.HEIGHT * unit
        val left = (size.width - width) / 2
        val top = (size.height - height) / 2
        val anchor = Offset(left + LelvoMark.ZOOM_ANCHOR_X * width, top + LelvoMark.ZOOM_ANCHOR_Y * height)
        val zoom = Matrix().apply {
            translate(anchor.x, anchor.y); scale(scale.value, scale.value); translate(-anchor.x, -anchor.y)
            translate(left, top); scale(unit, unit)
        }
        // One even-odd path, the screen with the mark cut out, as on iOS: an offscreen layer with a clear blend was
        // slow to draw at ×64.
        curtainPath.rewind()
        curtainPath.fillType = PathFillType.EvenOdd
        curtainPath.addRect(Rect(-1f, -1f, size.width + 1, size.height + 1))
        zoomedMark.rewind()
        zoomedMark.addPath(mark)
        zoomedMark.transform(zoom)
        curtainPath.addPath(zoomedMark)
        drawPath(curtainPath, LaunchColor)
        // The white mark over the hole, fading as the zoom begins.
        if (solid.value > 0f) drawPath(zoomedMark, Color.White, alpha = solid.value)
    }
}

internal fun markPath(): Path = PathParser().parsePathString(LelvoMark.CAMEL + " " + LelvoMark.CLOUD).toPath()
