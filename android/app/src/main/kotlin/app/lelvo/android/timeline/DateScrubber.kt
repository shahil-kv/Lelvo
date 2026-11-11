package app.lelvo.android.timeline

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** One section for the scrubber: its title and the grid index of its header. */
internal class ScrubSection(val title: String, val index: Int)

/**
 * The date scrubber (iOS `DateScrubber`, Google Photos' fast-scroll handle): it shows while the grid scrolls and
 * hides 1.5 s after; dragging it jumps section by section, shows the date in a pill and ticks once per new section.
 */
@Composable
internal fun DateScrubber(state: LazyGridState, sections: List<ScrubSection>, modifier: Modifier = Modifier) {
    if (sections.size < 2) return
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    var visible by remember { mutableStateOf(false) }
    var dragging by remember { mutableStateOf(false) }
    var dragFraction by remember { mutableFloatStateOf(0f) }
    var current by remember { mutableIntStateOf(-1) }
    val latest by rememberUpdatedState(sections)

    LaunchedEffect(state.isScrollInProgress, dragging) {
        if (state.isScrollInProgress || dragging) visible = true else { delay(1_500); visible = false }
    }
    val alpha by animateFloatAsState(if (visible || dragging) 1f else 0f, label = "scrubber")

    BoxWithConstraints(modifier.fillMaxHeight().padding(vertical = 8.dp).semantics { contentDescription = "Date scrubber. Drag to jump to a date" }) {
        val density = LocalDensity.current
        val thumb = 44.dp
        val track = with(density) { (maxHeight - thumb).toPx().coerceAtLeast(1f) }
        val info = state.layoutInfo
        val scrolled = if (info.totalItemsCount <= info.visibleItemsInfo.size) 0f
        else state.firstVisibleItemIndex.toFloat() / (info.totalItemsCount - info.visibleItemsInfo.size).coerceAtLeast(1)
        val fraction = if (dragging) dragFraction else scrolled.coerceIn(0f, 1f)
        Row(
            Modifier.align(Alignment.TopEnd).offset { IntOffset(0, (fraction * track).toInt()) }.alpha(alpha)
                .pointerInput(Unit) {
                    detectVerticalDragGestures(
                        onDragStart = { if (alpha > 0f) dragging = true },
                        onDragEnd = { dragging = false; current = -1 },
                        onDragCancel = { dragging = false; current = -1 },
                    ) { change, delta ->
                        if (!dragging) return@detectVerticalDragGestures
                        change.consume()
                        dragFraction = (dragFraction + delta / track).coerceIn(0f, 1f)
                        val list = latest
                        val i = (dragFraction * list.size).toInt().coerceAtMost(list.lastIndex)
                        if (i != current) {
                            current = i
                            haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                            scope.launch { state.scrollToItem(list[i].index) }
                        }
                    }
                },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AnimatedVisibility(dragging, enter = fadeIn(), exit = fadeOut()) {
                val list = sections
                Surface(shape = CircleShape, tonalElevation = 6.dp, shadowElevation = 3.dp, modifier = Modifier.padding(end = 8.dp)) {
                    Text(
                        list.getOrNull(current.coerceAtLeast(0))?.title.orEmpty(),
                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                    )
                }
            }
            Surface(shape = RoundedCornerShape(topStart = 22.dp, bottomStart = 22.dp), tonalElevation = 6.dp, shadowElevation = 3.dp) {
                Icon(painterResource(R.drawable.ic_unfold), null, Modifier.size(width = 32.dp, height = thumb).padding(6.dp))
            }
        }
    }
}
