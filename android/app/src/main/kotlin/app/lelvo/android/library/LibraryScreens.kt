package app.lelvo.android.library

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.onboarding.OnboardingField
import app.lelvo.android.onboarding.OnboardingPage
import app.lelvo.android.onboarding.PrimaryButton
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.crypto.Passphrase
import app.lelvo.core.crypto.RecoveryKey
import app.lelvo.core.format.LibraryNames
import app.lelvo.data.LibraryException
import app.lelvo.data.LibraryScanner
import app.lelvo.data.LibraryService
import app.lelvo.data.LibraryService.ChannelChoice
import app.lelvo.telegram.TelegramException
import java.text.NumberFormat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private fun Throwable.sentence(): String = when (this) {
    is LibraryException -> message.orEmpty()
    is TelegramException -> friendly
    else -> "Something went wrong. Try again."
}

/**
 * The library half of iOS `OnboardingModel`: the channel search, choosing, renaming, creating and unlocking. With no
 * [library] it's the debug preview: sample libraries, and nothing reaches Telegram.
 */
@Stable
class LibrarySetup(
    private val library: LibraryService?,
    private val scope: CoroutineScope,
    private val scanner: LibraryScanner? = null,
    /** Links what the scan found to the photos on this phone (iOS `relinkRestoredItems` after the restore scan). */
    val relink: suspend () -> Unit = {},
) {
    var channels by mutableStateOf<List<ChannelChoice>>(emptyList())
        private set
    var loading by mutableStateOf(false)
        private set
    var busy by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
    var selectedId by mutableStateOf<Long?>(null)
    var newName by mutableStateOf(LibraryNames.DEFAULT)
    var passphrase by mutableStateOf("")
    var confirm by mutableStateOf("")
    var acknowledged by mutableStateOf(false)

    /** Files found so far by the scan after unlocking. */
    var scanned by mutableIntStateOf(0)
        private set
    /** The scan is done (or wasn't needed, for a new library): the photos step is next. */
    var scanDone by mutableStateOf(false)
        private set
    /** What the scan found, at the start of the photos step's line (iOS `info`). */
    var found by mutableStateOf<String?>(null)
        private set
    private var scanJob: Job? = null

    val libraries: List<ChannelChoice> get() = channels.filter { it.isLibrary }

    val newPassphraseProblem: String? get() = passphraseProblem(passphrase, confirm, acknowledged)

    private fun found(list: List<ChannelChoice>) {
        channels = list
        // "Lelvo Library 2" when "Lelvo Library" exists, unless the name was already changed by hand.
        if (newName.startsWith(LibraryNames.DEFAULT)) newName = LibraryNames.unused(LibraryNames.DEFAULT, list.map { it.title })
    }

    fun load() {
        if (loading) return
        val library = library ?: return
        loading = true
        busy = false
        scope.launch {
            // Right after sign-in Telegram may still be syncing the chat list: retry before concluding there's no library.
            for (attempt in 0..2) {
                try {
                    found(library.candidateChannels())
                    error = null
                    if (channels.any { it.isLibrary } || attempt == 2) break
                } catch (e: Exception) {
                    error = e.sentence()
                }
                delay(2_000)
            }
            loading = false
        }
    }

    private fun run(work: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try { work() } catch (e: Exception) { error = e.sentence() } finally { busy = false }
        }
    }

    fun choose(c: ChannelChoice, then: () -> Unit) = run {
        library?.useExisting(c.id) ?: delay(600)
        then()
    }

    fun rename(c: ChannelChoice, title: String) = run {
        val library = library
        if (library == null) {
            found(channels.map { if (it.id == c.id) it.copy(title = title.trim().take(128)) else it })
        } else {
            library.rename(c.id, title)
            found(library.candidateChannels())
        }
    }

    fun create(then: (RecoveryKey) -> Unit) = run {
        val name = newName.trim().take(128).ifEmpty { LibraryNames.DEFAULT }
        val key = library?.createLibrary(name, passphrase) ?: RecoveryKey.random().also { delay(1_500) }
        passphrase = ""; confirm = ""; acknowledged = false
        // A new library is empty: nothing to scan.
        scanDone = true
        found = null
        then(key)
    }

    fun unlock(then: () -> Unit) = run {
        if (library == null) { delay(1_000); throw LibraryException.wrongPassphrase }
        library.unlock(passphrase)
        passphrase = ""
        then()
    }

    /** Reads the whole channel into the index (iOS `scan(full:)`). Read-only on Telegram. */
    fun scan() {
        if (scanDone || scanJob?.isActive == true) return
        error = null
        scanned = 0
        scanJob = scope.launch {
            try {
                val items = if (scanner != null) {
                    scanner.fullScan { n -> scope.launch { scanned = n } }.items.also { relink() }
                } else {
                    for (i in 1..40) { delay(50); scanned = i * 31 }
                    1_240
                }
                found = if (items == 0) "Your library is empty: a fresh start." else "Found ${NumberFormat.getIntegerInstance().format(items)} items in your library."
                scanDone = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.sentence()
            }
        }
    }

    companion object {
        /** Why the passphrase isn't ready yet (null = ready). Compared as it'll be used, like iOS. */
        fun passphraseProblem(passphrase: String, confirm: String, acknowledged: Boolean): String? {
            val p = Passphrase.normalized(passphrase)
            if (p.codePointCount(0, p.length) < 10) return "Use at least 10 characters. A few random words work well."
            if (p != Passphrase.normalized(confirm)) return "The passphrases don't match."
            if (!acknowledged) return "Confirm you understand that losing both the passphrase and the recovery key means losing your photos."
            return null
        }

        /** Debug preview: `found`, `found2`, `none`, `error`, `searching`, `scanning` or `photos`. */
        fun preview(kind: String, scope: CoroutineScope) = LibrarySetup(null, scope).apply {
            when (kind) {
                "found" -> found(listOf(ChannelChoice(1, "Lelvo Library", true, true)))
                "found2" -> found(listOf(ChannelChoice(1, "Lelvo Library", true, true), ChannelChoice(2, "Family photos", true, false)))
                "error" -> error = "Couldn't reach Telegram. Check your connection and try again."
                "searching" -> loading = true
                "photos" -> { found = "Found 1,240 items in your library."; scanDone = true }
            }
        }
    }
}

/** One clear decision: restore the library we found, or create one. Everything else is a secondary link (iOS `LibraryScreen`). */
@Composable
fun LibraryScreen(setup: LibrarySetup, onChosen: () -> Unit, onCreated: (RecoveryKey) -> Unit, onSignOut: () -> Unit) {
    var creating by rememberSaveable { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<ChannelChoice?>(null) }
    LaunchedEffect(Unit) { setup.load() }
    val libraries = setup.libraries
    val haptics = LocalHapticFeedback.current

    when {
        creating -> NewLibraryPage(setup, onBack = { creating = false }, onCreated = { creating = false; onCreated(it) })
        setup.loading && setup.channels.isEmpty() -> Searching()
        setup.error != null && setup.channels.isEmpty() -> OnboardingPage(
            icon = R.drawable.ic_wifi_off, title = "Couldn't check your channels",
            subtitle = "We need to look for an existing library before creating a new one.",
            error = setup.error,
            button = PrimaryButton("Try again", enabled = true) { setup.load() },
        ) { SecondaryLinks(setup, showCreate = false, onCreate = {}, onSignOut = onSignOut) }
        libraries.isNotEmpty() -> {
            val chosen = libraries.firstOrNull { it.id == setup.selectedId } ?: libraries[0]
            OnboardingPage(
                icon = R.drawable.ic_cloud_done, title = "Welcome back",
                subtitle = if (libraries.size == 1) "We found your library in Telegram. Restore it to see everything you've backed up."
                else "We found ${libraries.size} libraries in your Telegram. Choose the one to use on this phone.",
                error = setup.error, busy = setup.busy,
                button = PrimaryButton("Restore “${chosen.title}”", enabled = true) { setup.choose(chosen, onChosen) },
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    libraries.forEach { c ->
                        LibraryCard(
                            title = c.title, encrypted = c.encrypted, selected = c.id == chosen.id,
                            onRename = { renaming = c },
                            onClick = { haptics.performHapticFeedback(HapticFeedbackType.SegmentTick); setup.selectedId = c.id },
                        )
                    }
                    SecondaryLinks(setup, showCreate = true, onCreate = { creating = true }, onSignOut = onSignOut)
                }
            }
        }
        // First time: one library is made for you. Every new library is end-to-end encrypted.
        else -> OnboardingPage(
            icon = R.drawable.ic_verified_user, title = "Your library",
            subtitle = "Lelvo makes a private, encrypted channel in your Telegram. Only you can open what's in it.",
            error = setup.error, busy = setup.busy,
            button = PrimaryButton(
                "Create my library", enabled = setup.newPassphraseProblem == null && setup.newName.isNotBlank(),
                busyTitle = "Locking your library…",
            ) { setup.create(onCreated) },
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                NameRow(setup)
                PassphraseSetup(setup)
                SecondaryLinks(setup, showCreate = false, onCreate = {}, onSignOut = onSignOut)
            }
        }
    }

    renaming?.let { c -> RenameDialog(c.title, onDismiss = { renaming = null }, onSave = { setup.rename(c, it); renaming = null }) }
}

/** iOS shows a sheet over "Welcome back"; here it's a page of its own, and Back closes it. */
@Composable
internal fun NewLibraryPage(setup: LibrarySetup, onBack: () -> Unit, onCreated: (RecoveryKey) -> Unit) {
    BackHandler(enabled = !setup.busy, onBack = onBack)
    OnboardingPage(
        icon = R.drawable.ic_add_circle, title = "New library",
        subtitle = "A new, empty library is created next to your current one.",
        onBack = onBack, error = setup.error, busy = setup.busy,
        button = PrimaryButton(
            "Create library", enabled = setup.newPassphraseProblem == null && setup.newName.isNotBlank(),
            busyTitle = "Locking your library…",
        ) { setup.create(onCreated) },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            OnboardingField("Library name", setup.newName, { setup.newName = it })
            PassphraseSetup(setup)
        }
    }
}

@Composable
private fun Searching() {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            Modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterVertically),
        ) {
            CircularProgressIndicator(Modifier.size(40.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("Looking for your library…", style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold))
            Text("Checking your Telegram channels", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** The name is filled in for you; renaming is one tap away and can be done later too. */
@Composable
private fun NameRow(setup: LibrarySetup) {
    var editing by rememberSaveable { mutableStateOf(false) }
    if (editing) {
        OnboardingField("Library name", setup.newName, { setup.newName = it }, autofocus = true, onSubmit = { editing = false })
    } else Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Lelvo.colors.fill).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Name", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(setup.newName, style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            TextButton(onClick = { editing = true }) { Text("Rename", color = Lelvo.colors.accent, fontWeight = FontWeight.SemiBold) }
        }
        Text("You can rename it any time in Settings.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SecondaryLinks(setup: LibrarySetup, showCreate: Boolean, onCreate: () -> Unit, onSignOut: () -> Unit) {
    Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (showCreate) LinkRow(R.drawable.ic_add_circle, "Start a new library instead", !setup.busy, onCreate)
        LinkRow(R.drawable.ic_account_circle, "Use a different Telegram account", !setup.busy, onSignOut)
    }
}

@Composable
private fun LinkRow(icon: Int, title: String, enabled: Boolean, onClick: () -> Unit) {
    val tint = if (enabled) Lelvo.colors.accent else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        Modifier.clip(RoundedCornerShape(8.dp)).clickable(enabled = enabled, role = Role.Button, onClick = onClick).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(icon), null, Modifier.size(20.dp), tint = tint)
        Spacer(Modifier.width(8.dp))
        Text(title, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium), color = tint)
    }
}

private val purple = Color(0xFFAF52DE)
private val indigo = Color(0xFF5856D6)
private val blue = Color(0xFF007AFF)

/** A library as a selectable card: name, encrypted or not, and a rename button when selected (iOS `LibraryCard`). */
@Composable
fun LibraryCard(
    title: String,
    encrypted: Boolean,
    selected: Boolean = false,
    badge: String? = null,
    onRename: (() -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    val shape = RoundedCornerShape(20.dp)
    val accent = Lelvo.colors.accent
    Row(
        Modifier.fillMaxWidth().clip(shape)
            .background(if (selected) Lelvo.colors.fillStrong else Lelvo.colors.fill)
            .border(1.5.dp, if (selected) accent else Color.Transparent, shape)
            .then(if (onClick != null) Modifier.clickable(role = Role.RadioButton, onClick = onClick) else Modifier)
            .semantics(mergeDescendants = onRename == null) { this.selected = selected }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(52.dp).clip(RoundedCornerShape(15.dp))
                .background(Brush.linearGradient(if (encrypted) listOf(purple, indigo) else listOf(blue, indigo))),
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(if (encrypted) R.drawable.ic_verified_user else R.drawable.ic_photo_library), null, Modifier.size(24.dp), tint = Color.White)
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold), maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (badge != null) {
                    Spacer(Modifier.width(6.dp))
                    Text(badge, style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold), color = accent,
                        modifier = Modifier.clip(CircleShape).background(accent.copy(alpha = 0.25f)).padding(horizontal = 7.dp, vertical = 2.dp))
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(painterResource(R.drawable.ic_lock), null, Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(4.dp))
                Text(if (encrypted) "End-to-end encrypted" else "Standard · private channel",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (selected && onRename != null) {
            Box(
                Modifier.size(34.dp).clip(CircleShape).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f))
                    .clickable(role = Role.Button, onClick = onRename).semantics { contentDescription = "Rename $title" },
                contentAlignment = Alignment.Center,
            ) { Icon(painterResource(R.drawable.ic_edit), null, Modifier.size(16.dp)) }
            Spacer(Modifier.width(10.dp))
        }
        Icon(
            painterResource(if (selected) R.drawable.ic_check_circle else R.drawable.ic_circle_outline), null, Modifier.size(24.dp),
            tint = if (selected) accent else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun RenameDialog(current: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename library") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Only the name changes. Your photos stay where they are.")
                OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("Name") })
            }
        },
        confirmButton = { TextButton(onClick = { onSave(text) }, enabled = text.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** The passphrase for a new library, with the warning that has to be ticked (iOS `PassphraseSetup`). */
@Composable
fun PassphraseSetup(setup: LibrarySetup) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OnboardingField("Passphrase (10+ characters)", setup.passphrase, { setup.passphrase = it }, secure = true, autofill = ContentType.NewPassword)
            OnboardingField("Repeat passphrase", setup.confirm, { setup.confirm = it }, secure = true, autofill = ContentType.NewPassword)
            val problem = LibrarySetup.passphraseProblem(setup.passphrase, setup.confirm, acknowledged = true)
            if (problem != null && setup.passphrase.isNotEmpty()) {
                Text(problem, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        RiskWarning(setup.acknowledged) { setup.acknowledged = it }
    }
}

/**
 * Three short lines and a tick that has to be tapped. A paragraph next to a switch read like terms and conditions on
 * iOS: people flipped the switch without reading it, and this is the one thing they must know.
 */
@Composable
private fun RiskWarning(acknowledged: Boolean, onChange: (Boolean) -> Unit) {
    val orange = Lelvo.colors.orange
    val haptics = LocalHapticFeedback.current
    val shape = RoundedCornerShape(18.dp)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(orange.copy(alpha = 0.1f)).border(1.dp, orange.copy(alpha = 0.35f), shape).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(R.drawable.ic_verified_user), null, Modifier.size(20.dp), tint = orange)
            Spacer(Modifier.width(8.dp))
            Text("Only you can unlock your photos", style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold))
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Point(R.drawable.ic_key, buildAnnotatedString { append("Your passphrase opens your library on every device.") })
            Point(R.drawable.ic_password, buildAnnotatedString { append("Next you'll get a recovery key, for when you forget it.") })
            Point(R.drawable.ic_warning, buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append("Lose both, and your photos are gone for good.") }
                append(" Nobody can reset them. Not Lelvo, not Telegram.")
            })
        }
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.onSurface.copy(alpha = if (acknowledged) 0.1f else 0.06f))
                .clickable(role = Role.Checkbox) {
                    haptics.performHapticFeedback(if (acknowledged) HapticFeedbackType.ToggleOff else HapticFeedbackType.ToggleOn)
                    onChange(!acknowledged)
                }
                .semantics { selected = acknowledged }
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                painterResource(if (acknowledged) R.drawable.ic_check_circle else R.drawable.ic_circle_outline), null, Modifier.size(26.dp),
                tint = if (acknowledged) Lelvo.colors.accent else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.width(10.dp))
            Text("I understand. I'll keep both safe.", style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold))
        }
    }
}

@Composable
private fun Point(icon: Int, text: androidx.compose.ui.text.AnnotatedString) {
    Row(Modifier.semantics(mergeDescendants = true) {}) {
        Icon(painterResource(icon), null, Modifier.padding(top = 2.dp).size(18.dp), tint = Lelvo.colors.orange)
        Spacer(Modifier.width(10.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium)
    }
}

/** Unlocks an encrypted library with its passphrase or recovery key (iOS `unlock`). Back chooses another library. */
@Composable
fun UnlockScreen(setup: LibrarySetup, onUnlocked: () -> Unit, onBack: () -> Unit) {
    BackHandler(enabled = !setup.busy, onBack = onBack)
    val submit = { if (setup.passphrase.isNotEmpty()) setup.unlock(onUnlocked) }
    OnboardingPage(
        icon = R.drawable.ic_verified_user, title = "Unlock your library",
        subtitle = "This library is end-to-end encrypted. Enter its passphrase, or its recovery key if you forgot the passphrase.",
        onBack = if (setup.busy) null else onBack, error = setup.error, busy = setup.busy,
        button = PrimaryButton("Unlock", enabled = setup.passphrase.isNotEmpty(), busyTitle = "Unlocking…") { submit() },
    ) {
        OnboardingField("Passphrase or recovery key", setup.passphrase, { setup.passphrase = it }, secure = true, autofill = ContentType.Password, autofocus = true, onSubmit = { submit() })
    }
}
