package app.lelvo.android.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.library.LibrarySetup
import app.lelvo.android.library.RecoveryKeyScreen
import app.lelvo.android.shell.Messages
import app.lelvo.core.crypto.RecoveryKey
import app.lelvo.data.LibraryException
import app.lelvo.telegram.TelegramException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

private enum class Change { RecoveryKey, Passphrase }

/**
 * Passphrase and recovery key (iOS `EncryptionSettingsView`): make a new recovery key, change the passphrase, or add
 * a recovery key to a library from before recovery keys (which upgrades its header; the photos in Telegram stay
 * exactly as they are). Dialogs where iOS uses sheets; the new key shows full screen, once.
 */
@Composable
internal fun EncryptionScreen(app: LelvoApp, onBack: () -> Unit) {
    val library = app.library
    var needsUpgrade by remember { mutableStateOf(library.needsHeaderUpgrade) }
    var change by remember { mutableStateOf<Change?>(null) }
    var shown by remember { mutableStateOf<RecoveryKey?>(null) }
    // What Telegram has now, not a copy saved earlier: decides between "Add" and "New recovery key".
    LaunchedEffect(Unit) { if (runCatching { library.refreshHeader() }.isSuccess) needsUpgrade = library.needsHeaderUpgrade }

    shown?.let { key ->
        RecoveryKeyScreen(key) { shown = null; needsUpgrade = library.needsHeaderUpgrade }
        return
    }
    SettingsPage("Passphrase and recovery key", onBack) {
        if (needsUpgrade) {
            Footnote(
                "This library has no recovery key yet: if you forget its passphrase, your photos can't be opened. Add one " +
                    "now. Your photos in Telegram stay exactly as they are.",
            )
        }
        SettingRow(if (needsUpgrade) "Add a recovery key" else "New recovery key",
            if (needsUpgrade) null else "Your old recovery key stops working") { change = Change.RecoveryKey }
        SettingRow("Change passphrase", if (needsUpgrade) "Your library also gets a recovery key" else "Your recovery key keeps working") {
            change = Change.Passphrase
        }
        Footnote("Your photos are encrypted on your devices. The passphrase or the recovery key opens them on a new device.")
    }

    when (change) {
        Change.RecoveryKey -> SecretDialog(
            title = if (needsUpgrade) "Add a recovery key" else "New recovery key",
            note = if (needsUpgrade) "Enter your passphrase to add a recovery key." else "Enter your passphrase. Your old recovery key will stop working.",
            fields = listOf("Passphrase" to ContentType.Password),
            problem = { null },
            onDismiss = { change = null },
        ) { values -> library.newRecoveryKey(values[0]).also { shown = it } }
        Change.Passphrase -> SecretDialog(
            title = "Change passphrase",
            note = if (needsUpgrade) "Your library also gets a recovery key." else "Your recovery key keeps working.",
            fields = listOf(
                "Current passphrase or recovery key" to ContentType.Password,
                "New passphrase (10+ characters)" to ContentType.NewPassword,
                "Repeat new passphrase" to ContentType.NewPassword,
            ),
            problem = { v -> if (v[1].isEmpty()) null else LibrarySetup.passphraseProblem(v[1], v[2], acknowledged = true) },
            onDismiss = { change = null },
        ) { values ->
            val key = library.changePassphrase(values[0], values[1])
            if (key != null) shown = key else Messages.show(Messages.Style.Success, "Passphrase changed", "Use the new one on your other devices.")
        }
        null -> {}
    }
}

/**
 * A dialog of secret fields whose action runs once every field is filled and [problem] has nothing to say. Argon2id
 * takes a few seconds, so the dialog stays open, saying it's working, until the action ends; an error stays in it.
 */
@Composable
private fun SecretDialog(
    title: String, note: String, fields: List<Pair<String, ContentType>>, problem: (List<String>) -> String?,
    onDismiss: () -> Unit, action: suspend (List<String>) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var values by remember { mutableStateOf(List(fields.size) { "" }) }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    val hint = problem(values)
    val ready = values.all { it.isNotEmpty() } && hint == null && !working
    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(note)
                fields.forEachIndexed { i, (label, type) ->
                    val last = i == fields.lastIndex
                    OutlinedTextField(
                        values[i], { v -> values = values.toMutableList().also { it[i] = v }; error = null },
                        singleLine = true, enabled = !working, label = { Text(label) },
                        isError = last && (error != null || hint != null),
                        supportingText = if (last) (error ?: hint)?.let { { Text(it) } } else null,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        modifier = Modifier.semantics { contentType = type },
                    )
                }
            }
        },
        confirmButton = {
            TextButton(enabled = ready, onClick = {
                working = true
                scope.launch {
                    try {
                        action(values)
                        onDismiss()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        error = when (e) {
                            is LibraryException -> e.message
                            is TelegramException -> e.friendly
                            else -> "Something went wrong. Try again."
                        }
                    } finally {
                        working = false
                    }
                }
            }) { Text(if (working) "Working…" else "Continue") }
        },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !working) { Text("Cancel") } },
    )
}
