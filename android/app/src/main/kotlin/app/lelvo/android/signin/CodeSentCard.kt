package app.lelvo.android.signin

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.ui.theme.rememberReduceMotion
import app.lelvo.telegram.CodeDelivery
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.sin

private val TelegramBlue = Color(0xFF29ABEE)
// Google Messages' blue: on Android the text message lands there, not in a green bubble.
private val MessagesBlue = Color(0xFF1A73E8)
private val BubbleShape = RoundedCornerShape(17.dp, 17.dp, 17.dp, 5.dp)

/**
 * A small picture of where the login code landed: Telegram's service chat, or Messages for SMS (iOS `CodeSentCard`).
 * People waiting for an SMS didn't notice Telegram had sent the code to the Telegram app, so the code step shows them
 * what to look for. Plays once: typing dots, the message lands, a light runs across the code. Tap to replay;
 * Remove animations shows it at rest. Dark in both themes, like the chat it pictures.
 */
@Composable
fun CodeSentCard(delivery: CodeDelivery, open: (() -> Unit)?) {
    val telegram = delivery == CodeDelivery.Telegram
    val brand = if (telegram) TelegramBlue else MessagesBlue
    val bubble = if (telegram) Color(0xFF212B3B) else Color(0xFF2B2B2B)
    val reduce = rememberReduceMotion()
    var run by remember { mutableIntStateOf(0) }
    // 0 hidden, 1 card, 2 typing, 3 message
    var phase by remember { mutableIntStateOf(if (reduce) 3 else 0) }
    var glow by remember { mutableStateOf(false) }
    LaunchedEffect(run) {
        if (reduce) return@LaunchedEffect
        glow = false; phase = 0
        delay(80); phase = 1
        delay(280); phase = 2
        delay(750); phase = 3
        // A light runs across the code once, so the eye lands on it.
        delay(380); glow = true
        delay(520); glow = false
    }
    val shown by animateFloatAsState(if (phase == 0) 0f else 1f, spring(dampingRatio = 0.85f, stiffness = 300f), label = "card")
    Column(
        Modifier.fillMaxWidth()
            .graphicsLayer { alpha = shown; translationY = (1 - shown) * 12.dp.toPx(); scaleX = 0.96f + 0.04f * shown; scaleY = scaleX; transformOrigin = TransformOrigin(0.5f, 0f) }
            .clip(RoundedCornerShape(22.dp))
            .drawBehind {
                drawRect(Brush.verticalGradient(listOf(Color(0xFF1C1C1C), Color(0xFF121212))))
                // A faint wash of the app's colour, so the card reads as Telegram (or Messages) at a glance.
                drawRect(Brush.radialGradient(listOf(brand.copy(alpha = 0.16f), Color.Transparent), center = Offset.Zero, radius = 220.dp.toPx()))
            }
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(22.dp))
            .clickable(remember { MutableInteractionSource() }, indication = null, enabled = !reduce) { run++ }
            .padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).clearAndSetSemantics {
                contentDescription = if (telegram) "Example: the message from Telegram with your login code" else "Example: the text message with your login code"
            }, verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(24.dp).clip(CircleShape).background(if (telegram) Brush.verticalGradient(listOf(TelegramBlue, Color(0xFF219ED9))) else Brush.linearGradient(listOf(brand, brand))),
                    contentAlignment = Alignment.Center) {
                    Icon(painterResource(if (telegram) R.drawable.ic_send else R.drawable.ic_chat), null, Modifier.size(12.dp).offset(x = if (telegram) 1.dp else 0.dp), tint = Color.White)
                }
                Spacer(Modifier.width(10.dp))
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(if (telegram) "Telegram" else "Messages", style = MaterialTheme.typography.titleSmall, color = Color.White)
                        if (telegram) { Spacer(Modifier.width(3.dp)); Icon(painterResource(R.drawable.ic_verified), null, Modifier.size(14.dp), tint = TelegramBlue) }
                    }
                    Text(if (telegram) "service notifications" else "text message", style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.55f))
                }
            }
            if (open != null) {
                Row(Modifier.clip(CircleShape).background(TelegramBlue).clickable(onClick = open)
                    .semantics { role = Role.Button; contentDescription = "Open Telegram" }
                    .padding(horizontal = 13.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Open", style = MaterialTheme.typography.labelLarge, color = Color.White)
                    Spacer(Modifier.width(5.dp))
                    Icon(painterResource(R.drawable.ic_open_in_new), null, Modifier.size(14.dp), tint = Color.White)
                }
            }
        }
        Box(Modifier.fillMaxWidth().heightIn(min = 46.dp), contentAlignment = Alignment.BottomStart) {
            if (phase == 2) TypingDots(bubble)
            androidx.compose.animation.AnimatedVisibility(phase == 3, enter = fadeIn() + scaleIn(initialScale = 0.88f, transformOrigin = TransformOrigin(0f, 1f)), exit = fadeOut()) {
                Message(telegram, brand, bubble, glow)
            }
        }
    }
}

@Composable
private fun Message(telegram: Boolean, brand: Color, bubble: Color, glow: Boolean) {
    Column(Modifier.clip(BubbleShape).background(bubble).padding(horizontal = 12.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (telegram) "Login code:" else "Telegram code:", style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium), color = Color.White)
            Spacer(Modifier.width(5.dp))
            // Grey blocks, not digits: a made-up code would get typed in.
            Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                repeat(5) { i ->
                    val on by animateColorAsState(if (glow) brand else Color.White.copy(alpha = 0.3f), tween(200, delayMillis = i * 60), label = "block")
                    val s by animateFloatAsState(if (glow) 1.12f else 1f, tween(200, delayMillis = i * 60), label = "blockScale")
                    Box(Modifier.size(9.dp, 14.dp).graphicsLayer { scaleX = s; scaleY = s }.clip(RoundedCornerShape(3.dp)).background(on))
                }
            }
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Text(if (telegram) "Do not give this code to anyone, even if they say they are from Telegram." else "Don't share it with anyone.",
                style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.78f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false))
            Spacer(Modifier.width(8.dp))
            Text("now", style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.45f))
        }
    }
}

/** Telegram's three bouncing dots, only on screen for under a second. */
@Composable
private fun TypingDots(color: Color) {
    var t by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) { val start = withFrameNanos { it }; while (true) withFrameNanos { t = (it - start) / 1e9f } }
    Row(Modifier.clip(BubbleShape).background(color).padding(horizontal = 12.dp, vertical = 11.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        repeat(3) { i ->
            val wave = ((sin(t * 2 * PI * 1.2 - i * 0.9) + 1) / 2).toFloat()
            Box(Modifier.size(6.dp).graphicsLayer { translationY = -2.dp.toPx() * wave }.clip(CircleShape).background(Color.White.copy(alpha = 0.35f + 0.5f * wave)))
        }
    }
}
