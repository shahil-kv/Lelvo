package app.lelvo.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * Lelvo's colours, not the wallpaper's (no dynamic colour): the violet accent for what you can act on, the iPhone's
 * neutral greys for surfaces, and green, orange and red only for status (docs/DESIGN.md).
 */
private fun scheme(p: LelvoPalette, dark: Boolean): ColorScheme {
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = p.accent,
        onPrimary = if (dark) Color.Black else Color.White,
        primaryContainer = p.accentSoft,
        onPrimaryContainer = p.label,
        secondary = p.accent,
        onSecondary = if (dark) Color.Black else Color.White,
        secondaryContainer = p.accentSoft,
        onSecondaryContainer = p.label,
        tertiary = p.accent,
        background = p.background,
        onBackground = p.label,
        surface = p.background,
        onSurface = p.label,
        surfaceVariant = p.fill,
        onSurfaceVariant = p.secondary,
        surfaceTint = Color.Transparent,
        surfaceBright = p.cell,
        surfaceDim = p.grouped,
        surfaceContainerLowest = p.background,
        surfaceContainerLow = p.cell,
        surfaceContainer = p.fill,
        surfaceContainerHigh = p.fill,
        surfaceContainerHighest = p.fillStrong,
        outline = p.separator,
        outlineVariant = p.separator,
        error = p.red,
        onError = Color.White,
        inverseSurface = p.label,
        inverseOnSurface = p.background,
        inversePrimary = if (dark) LightPalette.accent else DarkPalette.accent,
    )
}

/** Status colours and grouped-list colours that Material's scheme has no slot for. */
val LocalLelvoPalette = staticCompositionLocalOf { LightPalette }

object Lelvo {
    val colors: LelvoPalette
        @Composable @ReadOnlyComposable get() = LocalLelvoPalette.current
}

@Composable
fun LelvoTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val palette = if (dark) DarkPalette else LightPalette
    CompositionLocalProvider(LocalLelvoPalette provides palette) {
        MaterialTheme(colorScheme = scheme(palette, dark), content = content)
    }
}
