package app.lelvo.android.onboarding

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lelvo.android.R
import app.lelvo.android.ui.theme.Lelvo

/**
 * One page of sign-in and library setup, laid out like the iPhone's `OnboardingPage`: a round Back button, a picture
 * (or the icon tile), a big title and a short line, the step's content, an error and a note, and the main button
 * pinned above the keyboard on a solid strip so fields scrolling under it never show through.
 */
@Composable
fun OnboardingPage(
    icon: Int,
    title: String,
    subtitle: String,
    onBack: (() -> Unit)? = null,
    button: PrimaryButton? = null,
    busy: Boolean = false,
    error: String? = null,
    info: String? = null,
    art: (@Composable () -> Unit)? = null,
    richSubtitle: AnnotatedString? = null,
    content: @Composable () -> Unit = {},
) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
            Box(Modifier.height(56.dp).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                if (onBack != null) BackCircle(onBack)
            }
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp).padding(top = 8.dp, bottom = 24.dp).widthIn(max = 560.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (art != null) Box(Modifier.padding(bottom = 6.dp)) { art() } else IconTile(icon)
                    Text(title, style = MaterialTheme.typography.headlineLarge.copy(fontWeight = FontWeight.Bold, fontSize = 32.sp, lineHeight = 38.sp),
                        modifier = Modifier.semantics { heading() })
                    Text(richSubtitle ?: AnnotatedString(subtitle), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                content()
                if (error != null) ErrorBanner(error)
                if (info != null) Row {
                    Icon(painterResource(R.drawable.ic_info), null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(6.dp))
                    Text(info, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (button != null) {
                Box(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).padding(horizontal = 24.dp, vertical = 12.dp)) {
                    PrimaryCapsuleButton(button.title, button.enabled, busy, button.busyTitle, button.run)
                }
            }
        }
    }
}

class PrimaryButton(val title: String, val enabled: Boolean, val busyTitle: String? = null, val run: () -> Unit)

@Composable
fun BackCircle(onBack: () -> Unit) {
    IconButton(onClick = onBack, modifier = Modifier.size(40.dp).clip(CircleShape).background(Lelvo.colors.fill)) {
        Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back", modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun IconTile(icon: Int) {
    Box(Modifier.size(64.dp).clip(RoundedCornerShape(18.dp)).background(Lelvo.colors.accent.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
        Icon(painterResource(icon), null, Modifier.size(34.dp), tint = Lelvo.colors.accent)
    }
}

/**
 * The iPhone's large capsule button: the strongest colour on the page (white on black in dark mode, black on white in
 * light), solid when disabled too so nothing scrolling under it shows through. Shrinks a little while pressed.
 */
@Composable
fun PrimaryCapsuleButton(title: String, enabled: Boolean = true, busy: Boolean = false, busyTitle: String? = null, run: () -> Unit) {
    val on = MaterialTheme.colorScheme.onSurface
    val bg = MaterialTheme.colorScheme.background
    val press = remember { MutableInteractionSource() }
    val pressed by press.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.97f else 1f, spring(stiffness = 900f), label = "press")
    val active = enabled || busy
    Box(
        Modifier.fillMaxWidth().widthIn(max = 520.dp).height(54.dp).graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(CircleShape).background(if (active) on else Lelvo.colors.fillStrong)
            .clickable(press, indication = null, enabled = enabled && !busy, onClick = run)
            .semantics { role = Role.Button },
        contentAlignment = Alignment.Center,
    ) {
        if (busy) Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(20.dp), color = bg, strokeWidth = 2.dp)
            if (busyTitle != null) { Spacer(Modifier.width(10.dp)); Text(busyTitle, style = MaterialTheme.typography.titleMedium, color = bg) }
        } else Text(title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
            color = if (enabled) bg else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The iPhone's `OnboardingField`: a filled rounded box, an accent ring while focused, an eye to show a password. */
@Composable
fun OnboardingField(
    placeholder: String,
    value: String,
    onValue: (String) -> Unit,
    modifier: Modifier = Modifier,
    keyboard: KeyboardType = KeyboardType.Text,
    secure: Boolean = false,
    autofocus: Boolean = false,
    autofill: ContentType? = null,
    onSubmit: () -> Unit = {},
) {
    var revealed by remember { mutableStateOf(false) }
    var focused by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    if (autofocus) LaunchedEffect(Unit) { focus.requestFocus() }
    Row(
        modifier.fillMaxWidth().height(54.dp).clip(RoundedCornerShape(14.dp)).background(Lelvo.colors.fill)
            .border(1.5.dp, if (focused) Lelvo.colors.accent else Color.Transparent, RoundedCornerShape(14.dp))
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) Text(placeholder, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            BasicTextField(
                value, onValue, singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                cursorBrush = SolidColor(Lelvo.colors.accent),
                visualTransformation = if (secure && !revealed) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(keyboardType = if (secure) KeyboardType.Password else keyboard, autoCorrectEnabled = false, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onSubmit() }, onGo = { onSubmit() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus).onFocusChanged { focused = it.isFocused }
                    .semantics { contentDescription = placeholder; if (autofill != null) contentType = autofill },
            )
        }
        if (secure) Icon(
            painterResource(if (revealed) R.drawable.ic_visibility_off else R.drawable.ic_visibility),
            contentDescription = if (revealed) "Hide" else "Show",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(22.dp).clickable { revealed = !revealed },
        )
    }
}

/** The iPhone's `ErrorBanner`: an orange triangle and one or two sentences on a soft orange box. */
@Composable
fun ErrorBanner(message: String) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Lelvo.colors.orange.copy(alpha = 0.12f)).padding(12.dp)) {
        Icon(painterResource(R.drawable.ic_warning), null, Modifier.size(16.dp), tint = Lelvo.colors.orange)
        Spacer(Modifier.width(8.dp))
        Text(message, style = MaterialTheme.typography.bodySmall, color = Lelvo.colors.orange)
    }
}
