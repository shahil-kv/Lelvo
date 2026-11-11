package app.lelvo.android.library

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import app.lelvo.android.R
import app.lelvo.android.brand.markPath
import app.lelvo.android.onboarding.ErrorBanner
import app.lelvo.android.onboarding.OnboardingPage
import app.lelvo.android.onboarding.PrimaryButton
import app.lelvo.android.onboarding.appSettings
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.android.ui.theme.LelvoMark
import app.lelvo.android.ui.theme.rememberReduceMotion
import app.lelvo.data.media.PhotoAccess
import java.text.NumberFormat

private val violet = Color(0xFF5200FF)

/** "Restoring your library" while the channel is read into the index (iOS `scanning`). */
@Composable
fun ScanningScreen(setup: LibrarySetup) {
    LaunchedEffect(Unit) { setup.scan() }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            Modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(22.dp, Alignment.CenterVertically),
        ) {
            RestoringMark()
            Text("Restoring your library", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold))
            val count = NumberFormat.getIntegerInstance().format(setup.scanned)
            AnimatedContent(
                targetState = count, label = "count",
                transitionSpec = { (slideInVertically { it / 2 } + fadeIn()) togetherWith (slideOutVertically { -it / 2 } + fadeOut()) },
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            ) { n ->
                Text("$n files found", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            setup.error?.let { e ->
                ErrorBanner(e)
                // iOS stays on the error with no way on; trying again reads from the start, which is always correct.
                TextButton(onClick = { setup.scan() }) { Text("Try again", color = Lelvo.colors.accent, fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

/** The mark in a violet glow that breathes (iOS `RestoringMark`). Still when animations are off. */
@Composable
private fun RestoringMark() {
    val moving = !rememberReduceMotion()
    val t = rememberInfiniteTransition(label = "glow")
    val phase by t.animateFloat(0f, 1f, infiniteRepeatable(tween(1_600, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "phase")
    val on = if (moving) phase else 1f
    val path = remember { markPath() }
    val ink = MaterialTheme.colorScheme.onSurface
    Canvas(Modifier.size(220.dp, 170.dp).clearAndSetSemantics {}) {
        val glow = (0.9f + 0.16f * on)
        scale(glow, Offset(size.width / 2, size.height / 2)) {
            drawCircle(
                Brush.radialGradient(listOf(violet.copy(alpha = 0.55f), Color.Transparent), center, radius = 110.dp.toPx()),
                radius = 110.dp.toPx(), alpha = 0.6f + 0.4f * on,
            )
        }
        val w = 120.dp.toPx()
        val unit = w / LelvoMark.WIDTH
        translate(center.x - w / 2, center.y - LelvoMark.HEIGHT * unit / 2) {
            scale(unit, Offset.Zero) { drawPath(path, ink) }
        }
    }
}

/**
 * The last step: ask for photos (iOS `photos`). Once access is decided the button finishes setup. The upload of the
 * first photo and "Your library is ready" (iOS `FirstBackupView`, `LibraryReadyView`) come with the backup engine.
 */
@Composable
fun PhotosStepScreen(setup: LibrarySetup, photos: PhotoAccess, onFinish: () -> Unit) {
    val context = LocalContext.current
    var status by remember { mutableStateOf(photos.status()) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { status = photos.markAsked() }
    // Coming back from Settings with access changed.
    LifecycleResumeEffect(Unit) { status = photos.status(); onPauseOrDispose {} }
    val decided = status != PhotoAccess.Status.NotAsked
    // Access just given: the restored items find their photos on this phone.
    LaunchedEffect(status) { if (status == PhotoAccess.Status.Full || status == PhotoAccess.Status.Partial) setup.relink() }
    val found = setup.found
    OnboardingPage(
        icon = R.drawable.ic_photo_library, title = "Back up your photos",
        subtitle = found?.let { "$it Allow access to all photos so everything on this phone is backed up too." }
            ?: "Allow access to all photos so everything on this phone is backed up.",
        button = if (decided) PrimaryButton("Start using Lelvo", enabled = true, run = onFinish)
        else PrimaryButton("Allow access", enabled = true) { ask.launch(photos.permissions) },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            when (status) {
                PhotoAccess.Status.Full -> StatusLine(R.drawable.ic_check_circle, Lelvo.colors.green, "Full access granted")
                PhotoAccess.Status.Partial ->
                    StatusLine(R.drawable.ic_info, Lelvo.colors.orange, "Limited access: only the photos you picked are backed up.")
                PhotoAccess.Status.Denied -> {
                    StatusLine(R.drawable.ic_warning, Lelvo.colors.red, "No access. You can still browse your cloud library.")
                    TextButton(onClick = { context.startActivity(appSettings(context.packageName)) }) {
                        Text("Open Settings", color = Lelvo.colors.accent, fontWeight = FontWeight.SemiBold)
                    }
                }
                PhotoAccess.Status.NotAsked -> {
                    Feature(R.drawable.ic_cloud_done, "Originals, bit for bit", "Full-quality photos and videos, any size.")
                    Feature(R.drawable.ic_play, "Stream from the cloud", "Watch backed-up videos without downloading them.")
                    Feature(R.drawable.ic_backup, "Comes back anywhere", "Reinstall or switch phones and it's all still there.")
                }
            }
        }
    }
}

@Composable
private fun StatusLine(icon: Int, tint: Color, text: String) {
    Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically) {
        Icon(painterResource(icon), null, Modifier.size(20.dp), tint = tint)
        Spacer(Modifier.width(8.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = tint)
    }
}

@Composable
private fun Feature(icon: Int, title: String, detail: String) {
    Row(Modifier.padding(vertical = 4.dp).semantics(mergeDescendants = true) {}) {
        Box(Modifier.width(30.dp).height(24.dp), contentAlignment = Alignment.Center) {
            Icon(painterResource(icon), null, Modifier.size(24.dp), tint = Lelvo.colors.accent)
        }
        Spacer(Modifier.width(14.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold))
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
