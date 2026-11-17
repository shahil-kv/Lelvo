package app.lelvo.android.timeline

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import kotlinx.coroutines.delay

/** One section for the scrubber: its title and the grid index of its header. */
internal class ScrubSection(val title: String, val index: Int)

/**
 * The date scrubber (iOS `DateScrubber`): a slim handle on the trailing edge. It appears while the grid scrolls,
 * hides 1.5 s after, and follows the finger. The date sits against the handle, and each new section ticks once.
 *
 * The drag reads the finger's place on the edge, not a running delta. A delta starting at zero jumped the handle
 * to the top on the first move.
 */
@Composable
internal fun DateScrubber(
    state: LazyGridState,
    sections: List<ScrubSection>,
    modifier: Modifier = Modifier,
    libraryStart: Int = 0,
    libraryCount: Int = 0,
    loadedCount: Int = 1,
    title: String = "",
    /** Fraction along the whole library. When set, the grid is not asked to scroll: that jump is what stuck the handle. */
    onFraction: ((fraction: Float, dragging: Boolean) -> Unit)? = null,
) {
    if (onFraction == null && sections.size < 2) return
    val haptics = LocalHapticFeedback.current
    var visible by remember { mutableStateOf(false) }
    var dragging by remember { mutableStateOf(false) }
    var dragFraction by remember { mutableFloatStateOf(0f) }
    var current by remember { mutableIntStateOf(-1) }
    val latest by rememberUpdatedState(sections)
    val grid by rememberUpdatedState(state)
    val jump by rememberUpdatedState(onFraction)

    LaunchedEffect(state.isScrollInProgress, dragging) {
        if (state.isScrollInProgress || dragging) visible = true else { delay(1_500); visible = false }
    }
    val alpha by animateFloatAsState(if (visible || dragging) 1f else 0f, tween(150), label = "scrubber")
    val open = visible || dragging

    BoxWithConstraints(
        modifier
            .width(44.dp)
            .fillMaxHeight()
            .semantics { contentDescription = "Date scrubber. Drag to jump to a date" }
            .then(if (open) Modifier.pointerInput(Unit) {
                val thumb = 44.dp.toPx()
                fun place(y: Float, draggingNow: Boolean) {
                    val track = (size.height - thumb).coerceAtLeast(1f)
                    dragFraction = ((y - thumb / 2f) / track).coerceIn(0f, 1f)
                    val report = jump
                    if (report != null) {
                        report(dragFraction, draggingNow)
                        return
                    }
                    val list = latest
                    if (list.isEmpty()) return
                    val i = (dragFraction * list.size).toInt().coerceIn(0, list.lastIndex)
                    if (i == current) return
                    current = i
                    haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                    grid.requestScrollToItem(list[i].index)
                }
                detectVerticalDragGestures(
                    onDragStart = { offset ->
                        dragging = true
                        place(offset.y, true)
                    },
                    onDragEnd = {
                        jump?.invoke(dragFraction, false)
                        dragging = false
                        current = -1
                    },
                    onDragCancel = {
                        jump?.invoke(dragFraction, false)
                        dragging = false
                        current = -1
                    },
                ) { change, _ ->
                    change.consume()
                    place(change.position.y, true)
                }
            } else Modifier),
    ) {
        val density = LocalDensity.current
        val thumb = 44.dp
        val track = with(density) { (maxHeight - thumb).toPx().coerceAtLeast(1f) }
        val fraction = if (dragging) dragFraction else {
            val scrolled = scrollFraction(state)
            if (libraryCount <= 0) scrolled
            else ((libraryStart + scrolled * loadedCount) / libraryCount).coerceIn(0f, 1f)
        }
        Row(
            Modifier
                .align(Alignment.TopEnd)
                .wrapContentWidth(Alignment.End, unbounded = true)
                .offset { IntOffset(0, (fraction * track).toInt()) }
                .alpha(alpha),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AnimatedVisibility(dragging, enter = fadeIn(tween(150)), exit = fadeOut(tween(150))) {
                Surface(shape = CircleShape, tonalElevation = 6.dp, shadowElevation = 3.dp, modifier = Modifier.padding(end = 8.dp)) {
                    Text(
                        if (onFraction != null) title else latest.getOrNull(current.coerceAtLeast(0))?.title.orEmpty(),
                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    )
                }
            }
            Surface(
                shape = RoundedCornerShape(13.dp),
                tonalElevation = 6.dp,
                shadowElevation = 3.dp,
                modifier = Modifier.padding(end = 4.dp).size(width = 26.dp, height = thumb),
            ) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Icon(painterResource(R.drawable.ic_unfold), contentDescription = null, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

/** How far down the loaded grid the viewport is, from item sizes rather than item counts. */
internal fun scrollFraction(state: LazyGridState): Float {
    val info = state.layoutInfo
    val visible = info.visibleItemsInfo
    if (info.totalItemsCount <= visible.size || visible.isEmpty()) return 0f
    val average = visible.sumOf { it.size.height }.toFloat() / visible.size
    if (average <= 0f) return 0f
    val scrolled = state.firstVisibleItemIndex * average + state.firstVisibleItemScrollOffset
    val total = info.totalItemsCount * average - info.viewportSize.height
    if (total <= 0f) return 0f
    return (scrolled / total).coerceIn(0f, 1f)
}
