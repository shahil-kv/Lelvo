# Design

How Lelvo looks on iPhone, Mac and the website. Values live in [design/tokens.json](../design/tokens.json); this file
says what each one is for.

## Changing a colour

1. Edit `design/tokens.json`.
2. Run `python3 Scripts/design-tokens.py`. It writes the `AccentColor` asset for both apps and the `:root` block of
   `website/styles.css`. `--check` reports stale files without writing.
3. Check light and dark mode on a device, and commit the tokens with the generated files.

Never edit the generated `:root` block or the `AccentColor.colorset` files by hand.

## Accent: electric violet

| | Light | Dark |
|---|---|---|
| Apps (`AccentColor`) | `#4E01F1` | `#9B7BFF` |
| Website (`--signal`) | `#4E01F1` | `#9B7BFF` |

The accent is the violet of the logo, so buttons, links and the icon read as one brand. It's far from Telegram's blue
and from the status colours. White text on `#4E01F1` and `#4E01F1` on white are both about 8 : 1, and `#9B7BFF` on
black is 6.7 : 1, 5.4 : 1 on dark grouped cells (WCAG AA).

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
(one email field), all on the left. On the right is one picture: the real app on an iPhone, with a Lelvo Library
channel card resting on it. Nothing else goes in the hero; it was cut down from photo walls, badges and a tap demo
because the first screen felt cluttered. Never use Telegram's logo or its look for the channel (Telegram API terms). The header and footer are the same on every page
(`index.html`, `404.html` and `Scripts/page.template.html`); change all three together.

## Logo and app icon

The mark is a camel whose neck flows into a cloud: the camel carries and keeps things, the cloud is where your photos
are kept. It's drawn in `design/logo/mark.svg` (two paths, `camel` and `cloud`). On the icon it's white on the brand
gradient, `violet` `#5200FF` at the bottom left to `deep` `#2A1A41` at the top right (`brand` in the tokens). The dark
icon is the camel in `violet-light` `#9B7BFF` (the app's dark accent) and the cloud in white, on black.

Logo files to hand out are in `design/logo/`, each as SVG and a 1024 PNG:

| File | Use on |
|---|---|
| `lelvo-icon` | The app icon: white mark on the brand gradient |
| `lelvo-icon-dark` | Dark mode: violet camel, white cloud, on black |
| `lelvo-icon-black` | Single colour: white mark on black |
| `lelvo-mark-violet` | The mark alone on light backgrounds |
| `lelvo-mark-white` | The mark alone on violet or photos |
| `lelvo-mark-dark` | The mark alone on dark backgrounds |

`python3 Scripts/brand-assets.py` draws everything from those two files: the SwiftUI shape and brand colours
(`Shared/Views/Brand/LelvoMark.swift`), the iOS icon with its dark and tinted versions, the Mac icon, the launch screen
(the white mark on `launch` `#3A0CA8`) and the website icons, including `website/favicon.svg`, which the site header
shows as its logo. It needs `resvg` (`brew install resvg`), because Quick Look and ImageMagick drop transparency or
gradients.

In the apps, use `Brand` colours only for the mark and the big moments (launch, end of setup, backup complete).
Everyday controls use the accent.
