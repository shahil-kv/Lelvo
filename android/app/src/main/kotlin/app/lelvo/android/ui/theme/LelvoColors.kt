package app.lelvo.android.ui.theme

import androidx.compose.ui.graphics.Color

// Generated from design/tokens.json by Scripts/design-tokens.py. Edit the tokens, not this file.

/** One palette per appearance: the iPhone's system colours and the Lelvo accent. */
class LelvoPalette(
    val accent: Color,
    val background: Color,
    val grouped: Color,
    val cell: Color,
    val fill: Color,
    val fillStrong: Color,
    val label: Color,
    val secondary: Color,
    val separator: Color,
    val accentSoft: Color,
    val green: Color,
    val orange: Color,
    val red: Color,
)

val LightPalette = LelvoPalette(
    accent = Color(0xFF4E01F1),
    background = Color(0xFFFFFFFF),
    grouped = Color(0xFFF2F2F7),
    cell = Color(0xFFFFFFFF),
    fill = Color(0xFFF2F2F7),
    fillStrong = Color(0xFFE5E5EA),
    label = Color(0xFF000000),
    secondary = Color(0xFF6C6C70),
    separator = Color(0xFFC6C6C8),
    accentSoft = Color(0xFFEFE9FF),
    green = Color(0xFF34C759),
    orange = Color(0xFFFF9500),
    red = Color(0xFFFF3B30),
)

val DarkPalette = LelvoPalette(
    accent = Color(0xFF9B7BFF),
    background = Color(0xFF000000),
    grouped = Color(0xFF000000),
    cell = Color(0xFF1C1C1E),
    fill = Color(0xFF1C1C1E),
    fillStrong = Color(0xFF2C2C2E),
    label = Color(0xFFFFFFFF),
    secondary = Color(0xFF98989F),
    separator = Color(0xFF38383A),
    accentSoft = Color(0xFF241A45),
    green = Color(0xFF30D158),
    orange = Color(0xFFFF9F0A),
    red = Color(0xFFFF453A),
)

/** The solid launch screen behind the white mark. */
val LaunchColor = Color(0xFF3A0CA8)
