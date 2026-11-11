package app.lelvo.android.signin

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.telephony.TelephonyManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import app.lelvo.android.R
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.activity.compose.BackHandler
import app.lelvo.data.DemoMode
import app.lelvo.telegram.AuthStep
import app.lelvo.telegram.CodeDelivery
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TelegramException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SignInScreen(td: TdClient, step: AuthStep, demo: DemoMode, onIntro: (() -> Unit)? = null) {
    // The review number was entered: the code step checks the demo code instead of Telegram's.
    var demoCode by rememberSaveable { mutableStateOf(false) }
    val phone = step == AuthStep.WaitPhone || step == AuthStep.NeedsCredentials
    // Back from the phone step returns to the intro, on the page the user left (iOS keeps `introPage` the same way).
    val back: (() -> Unit)? = if (demoCode) ({ demoCode = false }) else if (phone) onIntro else null
    BackHandler(enabled = back != null) { back?.invoke() }
    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (demoCode) "Enter the code" else title(step)) },
            navigationIcon = { back?.let { IconButton(onClick = it) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") } } },
        )
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).imePadding()) {
            when {
                demoCode -> DemoCodeStep(demo, onBack = { demoCode = false })
                // The demo works in a build without Telegram app keys too.
                phone ->
                    PhoneStep(td, demo, hasKeys = step == AuthStep.WaitPhone, onDemo = { demoCode = true })
                else -> when (step) {
                is AuthStep.WaitCode -> CodeStep(td, step)
                is AuthStep.WaitPassword -> PasswordStep(td, step.hint)
                AuthStep.WaitEmail -> Message(
                    "Telegram asks for an email login on this account. Sign in once in the official Telegram app, then try again.",
                )
                AuthStep.WaitRegistration -> Message(
                    "This number isn't registered on Telegram yet. Create an account in the Telegram app (it's free), then come back and sign in.",
                    action = "Use a different number" to { td.switchAccount() },
                )
                is AuthStep.WaitOtherDevice -> Message(
                    "Open Telegram on a device where you're signed in and approve this login.",
                )
                else -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                }
            }
        }
    }
}

private fun title(step: AuthStep) = when (step) {
    AuthStep.WaitPhone -> "Your phone number"
    is AuthStep.WaitCode -> "Enter the code"
    is AuthStep.WaitPassword -> "Password"
    AuthStep.WaitRegistration -> "No Telegram account"
    else -> "Lelvo"
}

@Composable
private fun StepColumn(content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) { content() }
}

/** Runs a sign-in call, turning Telegram's errors into the sentence the screen shows. */
private suspend fun attempt(setError: (String?) -> Unit, setBusy: (Boolean) -> Unit, block: suspend () -> Unit) {
    setBusy(true); setError(null)
    try { block() } catch (e: TelegramException) {
        app.lelvo.core.support.AppLog.warn("Telegram refused: ${e.code} ${e.message}")
        setError(e.friendly)
    } finally { setBusy(false) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PhoneStep(td: TdClient, demo: DemoMode, hasKeys: Boolean, onDemo: () -> Unit) {
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
    // A number typed with its own "+" and a code the list doesn't know is sent as typed (E.164 allows 8–15 digits).
    val international = number.trimStart().startsWith("+")
    val valid = if (international) digits.length in 8..15 else digits.length in Countries.lengths(dial)
    val phone = if (international) "+$digits" else "+$dial$digits"
    val submit = {
        when {
            !valid || busy -> Unit
            demo.matches(phone) -> { error = null; onDemo() }
            !hasKeys -> error = "This build has no Telegram app keys. Add telegram.apiId and telegram.apiHash to android/local.properties and build again."
            else -> scope.launch { attempt({ error = it }, { busy = it }) { td.submitPhone(phone) } }
        }
    }

    StepColumn {
        Text(
            "Use the number of your Telegram account. It goes only to Telegram, which sends a code to your Telegram app.",
            style = MaterialTheme.typography.bodyLarge,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            val country = Countries.byDialCode(dial)
            OutlinedTextField(
                value = "+$dial", onValueChange = {}, readOnly = true, singleLine = true,
                label = { Text("Country code") },
                prefix = country?.let { { Text(it.flag + " ") } },
                modifier = Modifier.width(132.dp).clickable { picking = true },
                enabled = false,
            )
            Spacer(Modifier.width(8.dp))
            OutlinedTextField(
                value = number,
                onValueChange = { new ->
                    // A pasted or autofilled "+91 98765 43210" carries its own country code.
                    val d = new.filter { it.isDigit() }
                    val match = if (new.trimStart().startsWith("+")) Countries.matchPrefixOf(d) else null
                    if (match != null) { dial = match.dialCode; number = d.removePrefix(match.dialCode) } else number = new
                },
                label = { Text("Phone number") },
                singleLine = true,
                isError = error != null,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone, imeAction = ImeAction.Next),
                keyboardActions = KeyboardActions(onNext = { submit() }),
                modifier = Modifier.weight(1f).focusRequester(focus).semantics { contentType = ContentType.PhoneNumber },
            )
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(onClick = { submit() }, enabled = valid && !busy, modifier = Modifier.fillMaxWidth()) {
            Text(if (busy) "Sending…" else "Next")
        }
    }

    if (picking) {
        ModalBottomSheet(onDismissRequest = { picking = false }) {
            LazyColumn {
                items(Countries.all, key = { it.region }) { c ->
                    ListItem(
                        headlineContent = { Text(c.name) },
                        leadingContent = { Text(c.flag) },
                        trailingContent = { Text("+${c.dialCode}") },
                        modifier = Modifier.clickable { dial = c.dialCode; picking = false },
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

@Composable
private fun CodeStep(td: TdClient, step: AuthStep.WaitCode) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by rememberSaveable(step) { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var resendIn by remember(step) { mutableIntStateOf(step.resend?.afterSeconds ?: 0) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(step) { focus.requestFocus() }
    LaunchedEffect(step) { while (resendIn > 0) { delay(1000); resendIn-- } }

    val numeric = step.length > 0
    val length = step.length
    val submit = { c: String ->
        if (c.isNotBlank() && !busy) scope.launch { attempt({ error = it; code = "" }, { busy = it }) { td.submitCode(c.trim()) } }
    }

    StepColumn {
        Text(step.info, style = MaterialTheme.typography.bodyLarge)
        OutlinedTextField(
            value = code,
            onValueChange = { new ->
                code = if (numeric) new.filter { it.isDigit() }.take(length) else new
                // Codes of any length: submit when Telegram's length is reached (iOS fixed a 5-digit-only bug).
                if (numeric && code.length == length) submit(code)
            },
            label = { Text("Login code") },
            singleLine = true,
            isError = error != null,
            keyboardOptions = KeyboardOptions(
                keyboardType = if (numeric) KeyboardType.NumberPassword else KeyboardType.Text,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { submit(code) }),
            modifier = Modifier.fillMaxWidth().focusRequester(focus).semantics { contentType = ContentType.SmsOtpCode },
        )
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Text(
            "Do not give this code to anyone, even if they say they are from Telegram.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (step.delivery == CodeDelivery.Telegram) {
            var notInstalled by remember { mutableStateOf(false) }
            TextButton(onClick = { notInstalled = !openTelegram(context) }) { Text("Open Telegram") }
            if (notInstalled) Text("Telegram isn't on this phone. Open it on the phone or computer where you use it.")
        }
        step.resend?.let { r ->
            TextButton(
                onClick = { scope.launch { attempt({ error = it }, { busy = it }) { td.resendCode() } } },
                enabled = resendIn == 0 && !busy,
            ) { Text(if (resendIn > 0) "${r.label} in ${resendIn / 60}:${"%02d".format(resendIn % 60)}" else r.label) }
        }
        TextButton(onClick = { scope.launch { td.switchAccount() } }) { Text("Use a different number") }
    }
}

@Composable
private fun DemoCodeStep(demo: DemoMode, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var code by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    val submit = { c: String ->
        if (c == DemoMode.CODE) scope.launch { demo.enter() }
        else { error = "That code isn't right. Check the code in the review notes."; code = "" }
    }
    StepColumn {
        Text("Demo account: enter the code from the review notes.", style = MaterialTheme.typography.bodyLarge)
        OutlinedTextField(
            value = code,
            onValueChange = { new ->
                code = new.filter { it.isDigit() }.take(DemoMode.CODE.length)
                if (code.length == DemoMode.CODE.length) submit(code)
            },
            label = { Text("Login code") }, singleLine = true, isError = error != null,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { submit(code) }),
            modifier = Modifier.fillMaxWidth().focusRequester(focus),
        )
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        TextButton(onClick = onBack) { Text("Use a different number") }
    }
}

private fun openTelegram(context: Context): Boolean = try {
    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("tg://")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    true
} catch (_: ActivityNotFoundException) {
    false
}

@Composable
private fun PasswordStep(td: TdClient, hint: String) {
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    val submit = { if (password.isNotEmpty() && !busy) scope.launch { attempt({ error = it }, { busy = it }) { td.submitPassword(password) } } }

    StepColumn {
        Text("Your account is protected with an extra password.", style = MaterialTheme.typography.bodyLarge)
        OutlinedTextField(
            value = password, onValueChange = { password = it },
            label = { Text("Password") }, singleLine = true, isError = error != null,
            visualTransformation = PasswordVisualTransformation(),
            supportingText = hint.takeIf { it.isNotBlank() }?.let { { Text("Hint: $it") } },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { submit() }),
            modifier = Modifier.fillMaxWidth().focusRequester(focus).semantics { contentType = ContentType.Password },
        )
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(onClick = { submit() }, enabled = password.isNotEmpty() && !busy, modifier = Modifier.fillMaxWidth()) {
            Text("Next")
        }
    }
}

@Composable
private fun Message(text: String, action: Pair<String, suspend () -> Unit>? = null) {
    val scope = rememberCoroutineScope()
    StepColumn {
        Text(text, style = MaterialTheme.typography.bodyLarge)
        action?.let { (label, run) -> Button(onClick = { scope.launch { run() } }) { Text(label) } }
        Spacer(Modifier.height(8.dp))
    }
}
