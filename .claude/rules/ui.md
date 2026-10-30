---
paths:
  - "iOS/**"
  - "macOS/**"
  - "Shared/Views/**"
---

# Screens

- Look and talk like Apple's Photos and Settings: system controls, grouped forms, SF Symbols, Dynamic Type, dark
  and light mode. Prefer system colours and text styles over custom ones.
- The accent is `.tint` / `Color.accentColor`, never `.blue`. Status uses system green, orange and red. Roles are in
  `docs/DESIGN.md`; new colours go in `design/tokens.json`, then `python3 Scripts/design-tokens.py`.
- Every icon-only button gets an `accessibilityLabel`.
- Text: short sentences, plain words, no exclamation marks, "your Telegram library". Errors say what to do next.
- `Shared/Views` builds for both platforms. Use `Shared/Support/Platform.swift` helpers instead of `#if os(...)` in a
  screen; put platform-only screens in `iOS/` or `macOS/`.
- No PhotoKit fetch, SQLite query, hashing or file read in a view body or on the main actor. Do it in a service or
  model and publish the result.
- Grids (`NativePhotoGrid`, `MacPhotoGrid`) are performance-tuned collection views. Keep work per cell tiny; measure
  with `-autoScrollTest` if you change cell code.
- New launch arguments for tests go inside `#if DEBUG`.
- Check the change in the simulator or on a device; the pull request needs before and after screenshots.
