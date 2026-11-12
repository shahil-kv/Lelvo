package app.lelvo.android.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.ui.theme.Lelvo

/*
 * The pieces every Settings page is made of, the way Google Photos' and Android's settings look: a plain list with
 * section headers in the accent colour, a divider between sections, switches at the end of a row, and choices in a
 * dialog of radio buttons (iOS uses grouped cards, inline pickers and footers).
 */

/** A Settings page: back arrow, title, scrolling content. System back closes it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsPage(
    title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}, content: @Composable ColumnScope.() -> Unit,
) {
    BackHandler(onBack = onBack)
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") } },
                actions = { actions() },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).navigationBarsPadding(), content = content)
    }
}

@Composable
internal fun SectionHeader(text: String) {
    Text(
        text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp).semantics { heading() },
    )
}

@Composable
internal fun SectionDivider() = HorizontalDivider(Modifier.padding(top = 8.dp), color = Lelvo.colors.separator)

/** What iOS puts in a section footer: a short explanation under the rows. */
@Composable
internal fun Footnote(text: String) {
    Text(
        text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 8.dp),
    )
}

/** A setting: its name, and its value or a short explanation under it. */
@Composable
internal fun SettingRow(
    title: String, value: String? = null, icon: Int? = null, destructive: Boolean = false, enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    val colour = when {
        !enabled -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
        destructive -> Lelvo.colors.red
        else -> MaterialTheme.colorScheme.onSurface
    }
    ListItem(
        headlineContent = { Text(title, color = colour) },
        supportingContent = value?.takeIf { it.isNotEmpty() }?.let { { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) } },
        leadingContent = icon?.let { { Icon(painterResource(it), contentDescription = null, tint = if (destructive) colour else MaterialTheme.colorScheme.onSurfaceVariant) } },
        modifier = if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier,
    )
}

@Composable
internal fun ToggleRow(title: String, detail: String?, on: Boolean, enabled: Boolean = true, icon: Int? = null, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        leadingContent = icon?.let { { Icon(painterResource(it), contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant) } },
        supportingContent = detail?.let { { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) } },
        trailingContent = { Switch(on, onCheckedChange = null, enabled = enabled) },
        modifier = Modifier.toggleable(on, enabled = enabled, role = Role.Switch, onValueChange = onChange),
    )
}

/** Android Settings' list preference: the choices as radio buttons, picked with one tap. */
@Composable
internal fun <T> ChoiceDialog(title: String, choices: List<Pair<T, String>>, selected: T, onDismiss: () -> Unit, onPick: (T) -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                choices.forEach { (value, label) ->
                    ListItem(
                        headlineContent = { Text(label) },
                        leadingContent = { RadioButton(selected = value == selected, onClick = null) },
                        colors = androidx.compose.material3.ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
                        modifier = Modifier.selectable(value == selected, role = Role.RadioButton) { onPick(value); onDismiss() },
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** "1.2 GB": sizes the way Android's own Settings shows them. */
internal fun bytesText(context: android.content.Context, bytes: Long): String = android.text.format.Formatter.formatShortFileSize(context, bytes)
