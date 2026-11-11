---
paths:
  - "android/**"
---

# Android

## Every feature: learn from what already works

The iPhone app and popular open-source apps have already hit most edge cases. Start from their fixes, not from zero.

1. **Before code: read the iOS version.** Find the Swift code for the feature (`Shared/`, `Packages/LelvoCore`,
   `iOS/`), and its history: `git log --oneline -- <files>` and the pull requests behind fixes. Write down every edge
   case, guard and past bug it handles (in the step's notes in `docs/ANDROID_PLAN.md`).
2. **Before code: read one or two proven open-source apps** that do the same thing on Android (list below). Look for
   the problems they solved: issues and commits named "fix", device quirks, OEM bugs, Android version checks.
3. **Write the Android code** with those cases covered, in Android's own way.
4. **After code: compare again.** Walk the iOS code and the Android code side by side: inputs, errors, retries,
   cancellation, app killed mid-way, no network, low storage, permissions revoked, large files, empty states. List
   what Android misses and either fix it or write it down as a known gap. Also note iOS bugs found on the way; tell the
   owner rather than copying them.
5. A step isn't done until its "Done when" proof ran on an emulator or phone.

Licence: Lelvo is GPL-3.0 with a CLA. Read other projects to learn; write our own code. Copy code only from
Apache-2.0, MIT or BSD sources, with the credit in `NOTICE.md`. Never paste from GPL/AGPL apps (Telegram, Immich, Ente,
Fossify, Nextcloud) without the owner's yes.

## Reference apps by feature

| Feature | Look at |
|---|---|
| TDLib on Android, sign-in, files | `tdlib/td` `example/android` and `example/java`; Telegram X (`TGX-Android/Telegram-X`, uses TDLib) |
| Streaming a Telegram file to a player | Telegram Android (`DrKLO/Telegram`, `FileStreamLoadOperation`), Telegram X |
| Media3 player, custom `DataSource`, encrypted reads | `androidx/media` demos and issues |
| Grid, viewer, zoom, MediaStore | Fossify Gallery, `saket/telephoto`, Aves (Flutter, but its Android plumbing is native) |
| Backup, MediaStore changes, background work | Immich (`mobile/android`), Nextcloud Android auto upload, Ente Photos (`mobile`) |
| Deleting with the system prompt | Fossify Gallery, Immich |
| Argon2, AES-GCM, Keystore | `lambdapioneer/argon2kt`, Google Tink (for patterns), Ente's crypto docs |

## Look and feel: like Google Photos

Android users know Google Photos best, so Lelvo for Android should feel like it, not like the iPhone app
(owner, 2026-11-11). Same features and words as iOS; Google Photos' way of showing them.

- **Before each screen, look at how Google Photos does it** (and Files by Google, Gmail, Android Settings for
  non-photo screens), write it under the step's notes, then build it that way. Where the iOS screen uses an iOS-only
  pattern, use Google Photos' one instead:
  | iOS pattern | Android (Google Photos) way |
  |---|---|
  | Grouped rounded settings cards | Plain Material list with section headers, dividers between sections |
  | Toasts | Snackbars, with Undo where an action can be undone |
  | Sheets with Done / Cancel buttons | Bottom sheets and full-screen dialogs, back to close |
  | Segmented pills, chevrons | Filter chips, tabs, plain list rows |
  | Viewer toolbar | Bottom action row (Share, Favorite, Delete…), info by swiping up |
  | Selection with Select button | Long-press to start, drag to select more, count in the top bar |
  | Swipe-back edge gesture | System back and predictive back |
- Material 3 components only: top app bars, navigation bar, FAB where Google Photos would put one, edge-to-edge.
- Lelvo's own colours (`design/tokens.json`, dynamic colour off), not the wallpaper's.
- **Light and dark both**: every step is checked in both on the emulator before it's ticked.
- Every screen works with TalkBack (content descriptions) and large font sizes.
- Smooth first: stable keys in lazy lists, no work in composition, images sized to the cell, baseline profile before the beta.

## Code

- `core/` is pure Kotlin with no Android imports; its tests read `../docs/test-vectors/` in place.
- New libraries only from the approved list in `docs/ANDROID_PLAN.md`.
