package app.lelvo.android.shell

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDefaults
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Progress and result messages, so a tap always answers, also when there is nothing to do. The iOS `ToastCenter`,
 * shown the Android way: a snackbar above the navigation bar, with Stop on slow work and an action (Undo, View)
 * where one helps. One app-wide center, so work that outlives a screen can still answer.
 */
object Messages {
    enum class Style { Progress, Success, Failure, Info }

    data class Action(val label: String, val onClick: () -> Unit)

    data class Message(
        val style: Style,
        val title: String,
        val detail: String? = null,
        val progress: Float? = null,
        val canStop: Boolean = false,
        val action: Action? = null,
        // Tells two equal messages apart, so showing the same words again restarts the timer and the animation.
        val id: Long = 0,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _current = MutableStateFlow<Message?>(null)
    val current: StateFlow<Message?> = _current
    private var hideJob: Job? = null
    @Volatile private var stoppable: Job? = null
    private var nextId = 0L

    fun progress(title: String, detail: String? = null, fraction: Float? = null) {
        hideJob?.cancel()
        _current.value = Message(Style.Progress, title, detail, fraction, canStop = stoppable != null, id = ++nextId)
    }

    /** Moves the progress on screen. Does nothing once it's gone, so a late update can't bring it back. */
    fun update(fraction: Float) {
        _current.update { if (it?.style == Style.Progress) it.copy(progress = fraction) else it }
    }

    /** Runs slow work whose progress offers Stop. Stopping reaches [work] as cancellation. */
    suspend fun runStoppable(work: suspend () -> Unit) = coroutineScope {
        val job = launch { work() }
        stoppable = job
        job.join()
        if (stoppable === job) stoppable = null
    }

    fun stop() {
        stoppable?.cancel()
        stoppable = null
        dismiss()
    }

    /** Same default time on screen as iOS (3.5 s); failures usually pass 5. An action keeps it up longer to reach. */
    fun show(style: Style, title: String, detail: String? = null, seconds: Double = 3.5, action: Action? = null) {
        hideJob?.cancel()
        val message = Message(style, title, detail, action = action, id = ++nextId)
        _current.value = message
        val shown = if (action != null) maxOf(seconds, 6.0) else seconds
        hideJob = scope.launch {
            delay((shown * 1000).toLong())
            _current.update { if (it?.id == message.id) null else it }
        }
    }

    fun dismiss() {
        hideJob?.cancel()
        _current.value = null
    }
}

/** Material 3's navigation bar height, without the system navigation under it. */
val NavigationBarHeight = 80.dp

/** Shows [Messages] where the shell puts it: above the navigation bar, over every tab. */
@Composable
fun MessageHost(modifier: Modifier = Modifier) {
    val message by Messages.current.collectAsState()
    // Keeps the last message on screen while it slides away.
    val shown = remember { arrayOfNulls<Messages.Message>(1) }
    message?.let { shown[0] = it }
    AnimatedVisibility(
        visible = message != null,
        modifier = modifier,
        enter = slideInVertically { it / 2 } + fadeIn(),
        exit = fadeOut(),
    ) {
        val m = shown[0] ?: return@AnimatedVisibility
        // Progress stays until its work ends; only results can be swiped away.
        if (m.style == Messages.Style.Progress) MessageSnackbar(m)
        else {
            // A fresh swipe state per message, so one swiped away never leaves the next one off screen.
            key(m.id) {
                val state = rememberSwipeToDismissBoxState()
                LaunchedEffect(state.currentValue) {
                    if (state.currentValue != SwipeToDismissBoxValue.Settled) Messages.dismiss()
                }
                SwipeToDismissBox(state, backgroundContent = {}) { MessageSnackbar(m) }
            }
        }
    }
}

@Composable
private fun MessageSnackbar(m: Messages.Message) {
    val action: (@Composable () -> Unit)? = when {
        m.canStop -> { { TextButton(onClick = Messages::stop) { Text("Stop", color = SnackbarDefaults.actionColor) } } }
        m.action != null -> { { TextButton(onClick = { Messages.dismiss(); m.action.onClick() }) { Text(m.action.label, color = SnackbarDefaults.actionColor) } } }
        else -> null
    }
    Snackbar(
        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp).semantics { liveRegion = LiveRegionMode.Polite },
        action = action,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            if (m.style == Messages.Style.Progress) {
                val p = m.progress
                val color = SnackbarDefaults.contentColor
                if (p != null) CircularProgressIndicator(progress = { p }, Modifier.size(20.dp), color = color, strokeWidth = 2.dp)
                else CircularProgressIndicator(Modifier.size(20.dp), color = color, strokeWidth = 2.dp)
            }
            Column {
                Text(m.title, style = MaterialTheme.typography.bodyMedium)
                m.detail?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = SnackbarDefaults.contentColor.copy(alpha = 0.8f), maxLines = 2)
                }
            }
        }
    }
}
