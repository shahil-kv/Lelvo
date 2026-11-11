package app.lelvo.android.signin

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.telephony.TelephonyManager
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lelvo.android.R
import app.lelvo.android.onboarding.OnboardingField
import app.lelvo.android.onboarding.OnboardingPage
import app.lelvo.android.onboarding.PrimaryButton
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.data.DemoMode
import app.lelvo.telegram.AuthStep
import app.lelvo.telegram.CodeDelivery
import app.lelvo.telegram.CodeResend
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TelegramException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Telegram sign-in, step by step, laid out like the iPhone's (`OnboardingView`: `PhoneScreen`, `CodeScreen`, the
 * password, other device and no account pages). Back goes where the iPhone's goes: the phone step to the intro, every
 * later step to the phone step.
 */
@Composable
fun SignInScreen(td: TdClient, step: AuthStep, demo: DemoMode, onIntro: (() -> Unit)? = null) {
    // The number typed, kept for "Wrong number? …" and the SMS line, like the iPhone's `m.phone`.
    var phone by rememberSaveable { mutableStateOf("") }
    // The review number was entered: the code step checks the demo code instead of Telegram's.
    var demoCode by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val toPhone: () -> Unit = { scope.launch { td.switchAccount() } }
    when {
        demoCode -> {
            BackHandler { demoCode = false }
            DemoCodeStep(demo, phone, onBack = { demoCode = false })
        }
        // The demo works in a build without Telegram app keys too.
        step == AuthStep.WaitPhone || step == AuthStep.NeedsCredentials -> {
            BackHandler(enabled = onIntro != null) { onIntro?.invoke() }
            PhoneStep(td, demo, hasKeys = step == AuthStep.WaitPhone, onBack = onIntro,
                onDemo = { phone = it; demoCode = true }, onSent = { phone = it })
        }
        step is AuthStep.WaitCode -> { BackHandler(onBack = toPhone); CodeStep(td, step, phone, toPhone) }
        step is AuthStep.WaitPassword -> { BackHandler(onBack = toPhone); PasswordStep(td, step.hint, toPhone) }
        step is AuthStep.WaitOtherDevice -> {
            BackHandler(onBack = toPhone)
            OnboardingPage(R.drawable.ic_phone, "Confirm on another device",
                "Open Telegram on a device where you're signed in and approve this login.", onBack = toPhone) {
                Text(step.link, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        step == AuthStep.WaitRegistration -> {
            val context = LocalContext.current
            BackHandler(onBack = toPhone)
            OnboardingPage(R.drawable.ic_info, "No Telegram account",
                "$phone isn't registered on Telegram yet. Create an account in the Telegram app (it's free), then come back and sign in.",
                onBack = toPhone, button = PrimaryButton("Get Telegram", true) { openStore(context) }) {
                LinkText("Use a different number", onClick = toPhone)
            }
        }
        step == AuthStep.WaitEmail -> {
            BackHandler(onBack = toPhone)
            OnboardingPage(R.drawable.ic_info, "Sign in with Telegram first",
                "Telegram asks for an email login on this account. Sign in once in the official Telegram app, then try again.", onBack = toPhone)
        }
        else -> Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        }
    }
}

/** Runs a sign-in call, turning Telegram's errors into the sentence the screen shows. */
private suspend fun attempt(setError: (String?) -> Unit, setBusy: (Boolean) -> Unit, block: suspend () -> Unit) {
    setBusy(true); setError(null)
    try { block() } catch (e: TelegramException) {
        app.lelvo.core.support.AppLog.warn("Telegram refused: ${e.code} ${e.message}")
        setError(e.friendly)
    } finally { setBusy(false) }
}

// Phone

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PhoneStep(td: TdClient, demo: DemoMode, hasKeys: Boolean, onBack: (() -> Unit)?, onDemo: (String) -> Unit, onSent: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var dial by rememberSaveable { mutableStateOf(Countries.defaultDialCode(simRegion(context))) }
    var number by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }

    val digits = number.filter { it.isDigit() }
    val valid = dial.isNotEmpty() && digits.length in Countries.lengths(dial)
    val phone = "+$dial$digits"
    val submit = {
        when {
            !valid || busy -> Unit
            demo.matches(phone) -> { error = null; onDemo(phone) }
            !hasKeys -> error = "This build has no Telegram app keys. Add telegram.apiId and telegram.apiHash to android/local.properties and build again."
            else -> { onSent(phone); scope.launch { attempt({ error = it }, { busy = it }) { td.submitPhone(phone) } } }
        }
    }
    OnboardingPage(
        R.drawable.ic_phone, "Your phone number",
        "Use the number of your Telegram account. It goes only to Telegram, which sends a code to your Telegram app.",
        onBack = onBack, button = PrimaryButton("Continue", valid) { submit() }, busy = busy, error = error,
    ) {
        val country = Countries.byDialCode(dial)
        val mono = MaterialTheme.typography.titleLarge.copy(color = MaterialTheme.colorScheme.onSurface, fontFeatureSettings = "tnum")
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Lelvo.colors.fill)) {
            Row(Modifier.fillMaxWidth().height(54.dp).clickable { picking = true }.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(country?.let { "${it.flag}  ${it.name}" } ?: "Choose a country", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                Icon(painterResource(R.drawable.ic_unfold), null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            HorizontalDivider(color = Lelvo.colors.separator.copy(alpha = 0.5f))
            Row(Modifier.fillMaxWidth().height(58.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("+", style = mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    BasicTextField(dial, { v -> dial = v.filter { it.isDigit() }.take(4) }, singleLine = true, textStyle = mono,
                        cursorBrush = SolidColor(Lelvo.colors.accent), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.width(52.dp).semantics { contentDescription = "Country code" })
                }
                VerticalDivider(Modifier.height(30.dp), color = Lelvo.colors.separator.copy(alpha = 0.6f))
                Box(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                    if (number.isEmpty()) Text("Phone number", style = mono, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    BasicTextField(
                        number,
                        { v ->
                            // Autofill gives the whole number with the country code: split it.
                            val d = v.filter { it.isDigit() }
                            val match = if (v.trimStart().startsWith("+")) Countries.matchPrefixOf(d) else null
                            number = if (match != null) { dial = match.dialCode; d.removePrefix(match.dialCode) } else d.take(Countries.lengths(dial).last)
                        },
                        singleLine = true, textStyle = mono, cursorBrush = SolidColor(Lelvo.colors.accent),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                        keyboardActions = KeyboardActions(onDone = { submit() }),
                        modifier = Modifier.fillMaxWidth().focusRequester(focus).semantics { contentType = ContentType.PhoneNumber; contentDescription = "Phone number" },
                    )
                }
            }
        }
    }

    if (picking) {
        ModalBottomSheet(onDismissRequest = { picking = false }) {
            var query by remember { mutableStateOf("") }
            OutlinedTextField(query, { query = it }, placeholder = { Text("Country or code") }, singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp))
            val q = query.filter { it.isDigit() }
            LazyColumn {
                items(Countries.all.filter { query.isBlank() || it.name.contains(query, ignoreCase = true) || (q.isNotEmpty() && it.dialCode.startsWith(q)) }, key = { it.region }) { c ->
                    ListItem(
                        headlineContent = { Text(c.name) },
                        leadingContent = { Text(c.flag) },
                        trailingContent = { Text("+${c.dialCode}") },
                        modifier = Modifier.clickable { dial = c.dialCode; picking = false; focus.requestFocus() },
                    )
                }
            }
        }
    }
}

private fun simRegion(context: Context): String? {
    val tm = context.getSystemService(TelephonyManager::class.java)
    return tm?.simCountryIso?.takeIf { it.isNotBlank() }?.uppercase()
        ?: tm?.networkCountryIso?.takeIf { it.isNotBlank() }?.uppercase()
        ?: java.util.Locale.getDefault().country.takeIf { it.isNotBlank() }
}

// Code

@Composable
private fun CodeStep(td: TdClient, step: AuthStep.WaitCode, phone: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by rememberSaveable(step) { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var telegramMissing by remember { mutableStateOf(false) }
    val submit = { c: String ->
        if (c.isNotBlank() && !busy) scope.launch { attempt({ error = it; if (it != null) code = "" }, { busy = it }) { td.submitCode(c.trim()) } }
    }
    val resendCode: () -> Unit = { scope.launch { attempt({ error = it }, { busy = it }) { td.resendCode() } } }
    CodeLayout(
        delivery = step.delivery, info = step.info, phone = phone, length = step.length, code = code, onCode = { code = it },
        submit = { submit(code) }, busy = busy, error = error, onBack = onBack,
        open = { telegramMissing = !openTelegram(context) }, telegramMissing = telegramMissing,
        resend = step.resend?.let { r -> r to resendCode },
        resendKey = step,
    )
}

@Composable
private fun DemoCodeStep(demo: DemoMode, phone: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val submit = {
        if (code == DemoMode.CODE) scope.launch { demo.enter() }
        else { error = "That code isn't right. Check the code in the review notes."; code = "" }
    }
    // Like the iPhone, the demo's code step is the "other" delivery: no chat card.
    CodeLayout(CodeDelivery.Other, "Demo account: enter the code from the review notes.", phone, DemoMode.CODE.length, code, { code = it },
        submit = { submit() }, busy = false, error = error, onBack = onBack, open = {}, telegramMissing = false, resend = null, resendKey = Unit)
}

/** The iPhone's `CodeScreen`: where the code went (card), where to look (title and line), digit boxes, resend, wrong number. */
@Composable
private fun CodeLayout(
    delivery: CodeDelivery, info: String, phone: String, length: Int, code: String, onCode: (String) -> Unit, submit: () -> Unit,
    busy: Boolean, error: String?, onBack: () -> Unit, open: () -> Unit, telegramMissing: Boolean,
    resend: Pair<CodeResend, () -> Unit>?, resendKey: Any,
) {
    val title = when (delivery) {
        CodeDelivery.Telegram -> "Check Telegram"
        CodeDelivery.Sms -> "Check your messages"
        CodeDelivery.Other -> "Enter the code"
    }
    val strong = SpanStyle(color = MaterialTheme.colorScheme.onSurface)
    // The words people scan for (where to look) in full colour, the rest dimmer.
    val rich = when (delivery) {
        CodeDelivery.Telegram -> buildAnnotatedString {
            append("It's in a chat from "); withStyle(strong) { append("Telegram") }; append(" in the Telegram app, ")
            withStyle(strong) { append("not in your SMS") }; append(".")
        }
        CodeDelivery.Sms -> buildAnnotatedString {
            append("We sent it by SMS to "); withStyle(strong) { append(phone) }; append(". Tap it above the keyboard to fill it in.")
        }
        CodeDelivery.Other -> null
    }
    val shake = remember { Animatable(0f) }
    LaunchedEffect(error) {
        if (error != null) for (x in listOf(10f, -10f, 7f, -7f, 3f, 0f)) shake.animateTo(x, tween(45))
    }
    val ready = if (length > 0) code.length >= length else code.isNotBlank()
    OnboardingPage(
        R.drawable.ic_chat, title, info.ifBlank { "We sent a code to your Telegram app." }, onBack = onBack,
        button = PrimaryButton("Continue", ready) { submit() }, busy = busy, error = error, richSubtitle = rich,
        art = if (delivery == CodeDelivery.Other) null else ({ key(delivery) { CodeSentCard(delivery, if (delivery == CodeDelivery.Telegram) open else null) } }),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Box(Modifier.graphicsLayer { translationX = shake.value.dp.toPx() }) {
                if (length > 0) DigitBoxes(length, code, error != null) { v ->
                    val d = v.filter { it.isDigit() }.take(length)
                    onCode(d)
                    // Codes of any length: submit when Telegram's length is reached (iOS fixed a 5-digit-only bug).
                    if (d.length == length && !busy) submit()
                } else OnboardingField("Code", code, onCode, autofocus = true, onSubmit = { if (code.isNotEmpty()) submit() })
            }
            if (delivery == CodeDelivery.Telegram && telegramMissing) {
                Text("Telegram isn't on this phone. Open it on the phone or computer where you use it.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            resend?.let { (r, run) -> ResendButton(r, resendKey, busy, run) }
            Text(buildAnnotatedString {
                withStyle(SpanStyle(color = MaterialTheme.colorScheme.onSurfaceVariant)) { append("Wrong number? ") }
                withStyle(SpanStyle(color = Lelvo.colors.accent)) { append(phone) }
            }, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.clickable(onClick = onBack))
        }
    }
}

/** One box per digit over a hidden field, so the system's one-time-code autofill and paste still work. */
@Composable
private fun DigitBoxes(length: Int, code: String, failed: Boolean, onCode: (String) -> Unit) {
    val focus = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Box(Modifier.fillMaxWidth().clickable(remember { MutableInteractionSource() }, indication = null) { focus.requestFocus() }) {
        BasicTextField(code, onCode, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
            textStyle = MaterialTheme.typography.bodySmall.copy(color = Color.Transparent), cursorBrush = SolidColor(Color.Transparent),
            modifier = Modifier.matchParentSize().graphicsLayer { alpha = 0.02f }.focusRequester(focus).onFocusChanged { focused = it.isFocused }
                .semantics { contentType = ContentType.SmsOtpCode; contentDescription = "Login code" })
        Row(horizontalArrangement = Arrangement.spacedBy(if (length > 5) 8.dp else 10.dp)) {
            repeat(length) { i ->
                val current = i == code.length && focused
                val ring = when { current -> Lelvo.colors.accent; failed -> Lelvo.colors.red.copy(alpha = 0.7f); else -> Color.Transparent }
                Box(Modifier.weight(1f).height(62.dp).clip(RoundedCornerShape(14.dp)).background(Lelvo.colors.fill)
                    .border(1.5.dp, ring, RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) {
                    Text(code.getOrNull(i)?.toString() ?: "", fontSize = 28.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

/** Greyed with a countdown until Telegram allows it, so a stuck person always sees a way forward. */
@Composable
private fun ResendButton(resend: CodeResend, key: Any, busy: Boolean, run: () -> Unit) {
    var left by remember(key) { mutableIntStateOf(resend.afterSeconds) }
    LaunchedEffect(key) { while (left > 0) { delay(1000); left-- } }
    val dim = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
    Text(buildAnnotatedString {
        withStyle(SpanStyle(color = MaterialTheme.colorScheme.onSurfaceVariant)) { append("Didn't get it? ") }
        withStyle(SpanStyle(color = if (left > 0) dim else Lelvo.colors.accent)) { append(resend.label) }
        if (left > 0) withStyle(SpanStyle(color = dim)) { append(" ${left / 60}:${"%02d".format(left % 60)}") }
    }, style = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum"),
        modifier = Modifier.clickable(enabled = left == 0 && !busy, onClick = run))
}

// Telegram's own login-code chat (user 42777, iOS `AppLinks.telegramCodeChat`); a Telegram too old for the link still
// opens at its chat list.
private fun openTelegram(context: Context): Boolean {
    for (link in listOf("tg://resolve?phone=42777", "tg://")) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return true
        } catch (_: ActivityNotFoundException) { }
    }
    return false
}

private fun openStore(context: Context) {
    val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=org.telegram.messenger")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try { context.startActivity(market) } catch (_: ActivityNotFoundException) {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://telegram.org/android")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

// Password

@Composable
private fun PasswordStep(td: TdClient, hint: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val submit = { if (password.isNotEmpty() && !busy) scope.launch { attempt({ error = it }, { busy = it }) { td.submitPassword(password) } } }
    OnboardingPage(
        R.drawable.ic_lock, "Two-step verification", "Your account is protected with an extra password.", onBack = onBack,
        button = PrimaryButton("Continue", password.isNotEmpty()) { submit() }, busy = busy, error = error,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OnboardingField("Password", password, { password = it }, secure = true, autofocus = true, onSubmit = { submit() },
                modifier = Modifier.semantics { contentType = ContentType.Password })
            if (hint.isNotBlank()) Text("Hint: $hint", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun LinkText(text: String, onClick: () -> Unit) {
    Text(text, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold), color = Lelvo.colors.accent,
        modifier = Modifier.clickable(onClick = onClick).padding(vertical = 4.dp))
}
