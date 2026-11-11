package app.lelvo.android.timeline

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.android.ui.theme.rememberReduceMotion
import app.lelvo.core.index.BackupBadge

/** The iPhone's symbol for each badge, as the closest Material icon. */
internal val BackupBadge.icon: Int
    get() = when (this) {
        BackupBadge.BackedUp -> R.drawable.ic_cloud_done
        BackupBadge.PhoneOnly -> R.drawable.ic_cloud_off
        BackupBadge.CloudOnly -> R.drawable.ic_cloud
        BackupBadge.Waiting -> R.drawable.ic_schedule
        BackupBadge.Uploading -> R.drawable.ic_sync
        BackupBadge.Failed -> R.drawable.ic_error
        BackupBadge.TooLarge -> R.drawable.ic_warning
    }

/** The iPhone's colours, on the dark circle a tile draws them on (iOS `BackupBadge.tint`). */
@Composable
internal fun BackupBadge.tint(): Color = when (this) {
    BackupBadge.BackedUp -> Color(0xFF30D158)
    BackupBadge.PhoneOnly, BackupBadge.Waiting -> Color.White
    BackupBadge.CloudOnly -> Color(0xFF64D2FF)
    BackupBadge.Uploading -> Lelvo.colors.accent
    BackupBadge.Failed -> Color(0xFFFF453A)
    BackupBadge.TooLarge -> Color(0xFFFF9F0A)
}

/** On the page background white would vanish in light mode (iOS `listTint`). */
@Composable
internal fun BackupBadge.listTint(): Color =
    if (this == BackupBadge.PhoneOnly || this == BackupBadge.Waiting) MaterialTheme.colorScheme.onSurfaceVariant else tint()

/** The small badge on a tile: 7 to 10 dp like the iPhone's, on a half-black circle; it turns while uploading. */
@Composable
internal fun BadgeMark(badge: BackupBadge, side: Dp, modifier: Modifier = Modifier) {
    val size = (side.value * 0.065f).coerceIn(7f, 10f).dp * 1.4f
    val spin = if (badge == BackupBadge.Uploading && !rememberReduceMotion()) {
        val t = rememberInfiniteTransition(label = "spin")
        val angle by t.animateFloat(0f, 360f, infiniteRepeatable(tween(1_200, easing = LinearEasing), RepeatMode.Restart), label = "angle")
        angle
    } else 0f
    Box(modifier.size(size + 4.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.5f)), contentAlignment = Alignment.Center) {
        Icon(painterResource(badge.icon), null, Modifier.size(size).graphicsLayer { rotationZ = -spin }, tint = badge.tint())
    }
}

/** "What the icons mean": every badge with its name and one line (iOS legend). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BadgeLegend(onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("What the icons mean", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
            for (badge in BackupBadge.entries) Row(Modifier.semantics(mergeDescendants = true) {}) {
                Icon(painterResource(badge.icon), null, Modifier.padding(top = 2.dp).size(22.dp), tint = badge.listTint())
                Spacer(Modifier.width(16.dp))
                Column {
                    Text(badge.label, style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold))
                    Text(badge.explanation, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
