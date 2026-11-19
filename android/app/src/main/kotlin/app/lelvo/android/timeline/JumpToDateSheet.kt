package app.lelvo.android.timeline

import android.widget.NumberPicker
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.lelvo.core.index.JumpToDate
import java.util.Calendar
import java.util.Locale

/**
 * Month and year wheels to jump the timeline (iOS `JumpToDateSheet`). Scrolls via the scrubber's date index;
 * no Telegram calls.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JumpToDateSheet(
    datesNewestFirst: LongArray,
    onDismiss: () -> Unit,
    onJump: (fraction: Double) -> Unit,
) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val years = remember(datesNewestFirst) { JumpToDate.yearRange(datesNewestFirst).toList() }
    val cal = remember { Calendar.getInstance() }
    val seed = datesNewestFirst.firstOrNull()?.takeIf { it > 0L } ?: System.currentTimeMillis()
    cal.timeInMillis = seed
    var month by remember { mutableIntStateOf(cal.get(Calendar.MONTH)) } // 0-based
    var year by remember(years) {
        val y = cal.get(Calendar.YEAR)
        mutableIntStateOf(years.firstOrNull { it == y } ?: years.lastOrNull() ?: y)
    }
    val monthLabels = remember {
        Array(12) { i ->
            cal.set(Calendar.MONTH, i)
            cal.getDisplayName(Calendar.MONTH, Calendar.LONG, Locale.getDefault()) ?: (i + 1).toString()
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            Text("Jump to date", style = MaterialTheme.typography.titleLarge)
            Text(
                "Scrolls the timeline. Your library stays on this device.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
            )
            Row(
                Modifier.fillMaxWidth().height(160.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                AndroidView(
                    factory = { ctx ->
                        NumberPicker(ctx).apply {
                            minValue = 0
                            maxValue = 11
                            displayedValues = monthLabels
                            wrapSelectorWheel = false
                            value = month
                            setOnValueChangedListener { _, _, v -> month = v }
                            contentDescription = "Month"
                        }
                    },
                    modifier = Modifier.weight(1f).height(160.dp),
                )
                AndroidView(
                    factory = { ctx ->
                        NumberPicker(ctx).apply {
                            val labels = years.map { it.toString() }.toTypedArray().ifEmpty { arrayOf(year.toString()) }
                            minValue = 0
                            maxValue = labels.lastIndex
                            // NumberPicker requires displayedValues length == maxValue - minValue + 1 before value.
                            displayedValues = labels
                            wrapSelectorWheel = false
                            value = years.indexOf(year).coerceIn(0, labels.lastIndex)
                            setOnValueChangedListener { _, _, v -> year = years.getOrElse(v) { year } }
                            contentDescription = "Year"
                        }
                    },
                    modifier = Modifier.weight(1f).height(160.dp),
                )
            }
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                TextButton(onClick = {
                    cal.clear()
                    cal.set(Calendar.YEAR, year)
                    cal.set(Calendar.MONTH, month)
                    cal.set(Calendar.DAY_OF_MONTH, 15)
                    val fraction = JumpToDate.fraction(cal.timeInMillis, datesNewestFirst)
                    onJump(fraction)
                    onDismiss()
                }) { Text("Go") }
            }
        }
    }
}
