package app.lelvo.android.library

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.onboarding.PrimaryCapsuleButton
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.crypto.RecoveryKey

/**
 * Shows a new recovery key once (iOS `RecoveryKeyView`). Nothing in Lelvo or Telegram keeps a readable copy, so the
 * user has to save it now; Back does nothing, so it can't be skipped by accident.
 */
@Composable
fun RecoveryKeyScreen(key: RecoveryKey, onDone: () -> Unit) {
    BackHandler {}
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    var copied by rememberSaveable { mutableStateOf(false) }
    // Groups of four, in rows of four: easy to copy onto paper without losing your place.
    val groups = key.text.split("-")
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                Column(Modifier.widthIn(max = 560.dp).padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(
                        Modifier.size(64.dp).clip(RoundedCornerShape(20.dp))
                            .background(Brush.linearGradient(listOf(Color(0xFF6E4AFF), Color(0xFFB89CFF)))),
                        contentAlignment = Alignment.Center,
                    ) { Icon(painterResource(R.drawable.ic_key), null, Modifier.size(30.dp), tint = Color.White) }
                    Text("Your recovery key", style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
                        modifier = Modifier.semantics { heading() })
                    Text("The only way back into your photos if you forget your passphrase. Keep it in a password manager or on paper.",
                        style = MaterialTheme.typography.bodyMedium, color = secondary, textAlign = TextAlign.Center)
                }
                Column(
                    Modifier.widthIn(max = 560.dp).fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(secondary.copy(alpha = 0.1f)).padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    SelectionContainer(Modifier.clearAndSetSemantics { contentDescription = "Recovery key: " + groups.joinToString(" ") }) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            groups.chunked(4).forEach { row ->
                                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    for (i in 0 until 4) {
                                        val g = row.getOrNull(i)
                                        if (g == null) Spacer(Modifier.weight(1f)) else Text(
                                            g, textAlign = TextAlign.Center,
                                            style = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold),
                                            modifier = Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).background(secondary.copy(alpha = 0.16f)).padding(vertical = 9.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(secondary.copy(alpha = 0.18f))
                            .clickable(role = Role.Button) {
                                copySecret(context, key.text)
                                copied = true
                                haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                                // Outlives this screen: the key is usually pasted after "I've saved it".
                                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ clearIfStill(context.applicationContext, key.text) }, 120_000)
                            }
                            .padding(vertical = 11.dp),
                        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val tint = if (copied) Lelvo.colors.green else MaterialTheme.colorScheme.onSurface
                        Icon(painterResource(if (copied) R.drawable.ic_check_circle else R.drawable.ic_content_copy), null, Modifier.size(18.dp), tint = tint)
                        Spacer(Modifier.width(8.dp))
                        Text(if (copied) "Copied" else "Copy", style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold), color = tint)
                    }
                }
                Row(Modifier.widthIn(max = 560.dp).fillMaxWidth().semantics(mergeDescendants = true) {}) {
                    Icon(painterResource(R.drawable.ic_warning), null, Modifier.padding(top = 2.dp).size(18.dp), tint = Lelvo.colors.orange)
                    Spacer(Modifier.width(10.dp))
                    Text(buildAnnotatedString {
                        withStyle(SpanStyle(color = Lelvo.colors.orange, fontWeight = FontWeight.SemiBold)) { append("Lose both and your photos are gone. ") }
                        append("Nobody can recover them. Not Lelvo, not Telegram.")
                    }, style = MaterialTheme.typography.bodyMedium)
                }
            }
            Box(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).padding(20.dp), contentAlignment = Alignment.Center) {
                PrimaryCapsuleButton("I've saved it", run = onDone)
            }
        }
    }
}

/** Copies without showing it in the clipboard preview or keyboard suggestions (Android 13+ reads the sensitive flag). */
private fun copySecret(context: Context, text: String) {
    val clip = ClipData.newPlainText("Recovery key", text)
    clip.description.extras = PersistableBundle().apply {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
        else putBoolean("android.content.extra.IS_SENSITIVE", true)
    }
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
}

/** Like iOS's two-minute expiry: clears the clipboard only if the key is still what's on it. */
private fun clearIfStill(context: Context, text: String) {
    val cm = context.getSystemService(ClipboardManager::class.java)
    val current = runCatching { cm.primaryClip?.getItemAt(0)?.text?.toString() }.getOrNull()
    if (current == text) runCatching { cm.clearPrimaryClip() }
}
