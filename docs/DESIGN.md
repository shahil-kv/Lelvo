# Design

How Lelvo looks on iPhone, Mac and the website. Values live in [design/tokens.json](../design/tokens.json); this file
says what each one is for.

## Changing a colour

1. Edit `design/tokens.json`.
2. Run `python3 Scripts/design-tokens.py`. It writes the `AccentColor` asset for both apps and the `:root` block of
   `website/styles.css`. `--check` reports stale files without writing.
3. Check light and dark mode on a device, and commit the tokens with the generated files.

Never edit the generated `:root` block or the `AccentColor.colorset` files by hand.

## Accent: indigo

| | Light | Dark |
|---|---|---|
| Apps (`AccentColor`) | `#5E4AE3` | `#8B7CFF` |
| Website (`--signal`) | `#5E4AE3` | `#8B7CFF` |

Indigo was chosen over the old blue because the old blue was Telegram's own colour and the iOS default tint, which
made Lelvo look like part of Telegram. Indigo keeps the calm, trustworthy feel of blue, and it doesn't clash with the
status colours or with people's photos. White text on `#5E4AE3` and `#5E4AE3` on white are both 5.9 : 1 (WCAG AA).

The accent marks what you can act on and what is happening now: buttons, toggles, links, selection, the active tab,
uploads in progress, and setting icons for backup itself. It is never used for status.

## App colours

The apps follow Apple's Photos and Settings: system colours, materials and text styles, with the accent as the only
custom colour.

- Brand and interaction: `.tint` or `Color.accentColor` in SwiftUI, `.tintColor` in UIKit. On the Mac, AppKit grids use
  `NSColor.controlAccentColor`, which follows the user's system accent unless it is set to Multicolor. That's intended.
- Status: system colours only, so they mean the same as everywhere else on iOS.
  - `.green`: backed up, done.
  - `.orange`: needs attention, paused.
  - `.red`: deletes or fails.
  - `.secondary` / `.gray`: not started.
- Settings icon tiles: the accent for backup settings, other system colours (`.teal`, `.purple`) for everything else,
  as in Settings. Don't use `.blue` or `.indigo` for a tile, because they read as a second accent.
- Over photos and video: `.white`, on a `.black.opacity(0.35)` backing where it needs contrast.
- Type: San Francisco through text styles (`.headline`, `.body`, …) so Dynamic Type works. No custom fonts in the apps.

## Website

Light by default. The moon button in the header switches to dark and remembers the choice (`theme.js` applies it
before the page draws; the CSP blocks inline scripts). Dark values live under `web-dark` in the tokens and only
override colours.

| Token | Use |
|---|---|
| `--paper` | Page background |
| `--surface` | Inputs, footer, code |
| `--ink` | Text, primary buttons |
| `--slate` | Secondary text |
| `--line` | Rules and borders |
| `--signal` | Links, focus rings, the early-access button, highlights |
| `--signal-soft` | Focus halo, text selection |
| `--on-signal` | Text on `--signal` (white in light, near-black in dark, for contrast) |
| `--verified` | "Backed up" ticks, same meaning as the apps' green |
| `--band`, `--band-ink`, `--band-mist`, `--band-link` | The deep indigo privacy band, the same in both themes |
| `--bezel`, `--bezel-edge` | Device frames around screenshots; the edge shows them on dark paper |
| `--shadow` | Shadows under phones and the status pill |
| `--display` | Bricolage Grotesque: headings, buttons, labels |
| `--text` | Source Serif 4: running text |
| `--measure`, `--wide`, `--gutter` | Line length, page width, side padding |
| `--ease` | All transitions |

The hero answers three questions in order: what it is (the headline), why it matters (one short line), what to do
(one email field), then three small trust points. Below it, sample photos drift up at the edges and the real app on an
iPhone sends photos into a Lelvo Library channel. Visitors can tap a photo to send it; left alone, it plays itself.
Never use Telegram's logo or its look for the channel (Telegram API terms). The header and footer are the same on every page
(`index.html`, `404.html` and `Scripts/page.template.html`); change all three together.

## App icon

A white cloud holding a photo on an indigo gradient, `#4D44EF` to `#4B2CC8` (top left to bottom right). The PNGs in
both `AppIcon.appiconset` folders and `website/apple-touch-icon.png` use these colours.
