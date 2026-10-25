# Development

How to build, run and test Memvo. For the code's design, see [ARCHITECTURE.md](ARCHITECTURE.md); for the
storage format, [CLOUD_FORMAT.md](CLOUD_FORMAT.md).

## Requirements

- A Mac with **Xcode 26 or later** (CI uses the newest stable Xcode).
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**: `brew install xcodegen`. The Xcode project is generated from
  `project.yml` and isn't committed, so the project never has merge conflicts.
- A Telegram account to test with. A spare account is best: tests upload real files to it.

## Layout

```text
project.yml                  XcodeGen spec: targets, Info.plist keys, schemes
Config/App.xcconfig          shared build settings; includes Config/Secrets.xcconfig if present
iOS/                         iPhone and iPad app: app entry, gallery grid (UICollectionView), viewer, App Intents
macOS/                       Mac app: window, sidebar, grid (NSCollectionView), viewer, menu bar, settings
Shared/                      compiled into both apps
  App/                       AppEnvironment (services), AppModel (UI state)
  Services/                  backup engine, Photos access, Keychain, logs, background work
  Services/Telegram/         TDLib session, library channel, uploads, ranged reads, video streaming
  Support/                   platform helpers, thumbnail pipeline, app links
  Views/                     sign-in, settings, backup, free up space, gallery model
Packages/MemvoCore/   platform-independent core: caption format, encryption, index, job queue, cache
UITests/                     iOS UI tests (demo library, no Telegram account needed)
website/                     the website: plain HTML, CSS and JS; Cloudflare deploys it on every push to main
Scripts/build.sh             command-line builds and tests
```

Code in `Shared/` must build for both platforms. Use the helpers in `Shared/Support/Platform.swift`
(`PlatformImage`, `PlatformActions`, `Haptics`, view modifiers) instead of `#if os(...)` in screens where possible.

## Telegram app keys

Every Telegram app needs an `api_id` and `api_hash` ([Telegram API terms §2.1](https://core.telegram.org/api/terms)).

- **Your own build:** log in at [my.telegram.org](https://my.telegram.org) → **API development tools** → create an
  app (title "Memvo dev", platform iOS). Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`
  and fill in both values. The app then starts sign-in at the phone number.
- **Without the file**, the app asks for the keys on its first screen, so anyone can build and run it.
- **Never commit `Config/Secrets.xcconfig`** (it's in `.gitignore`) and never paste keys into issues or logs.
- **Releases** use the project's keys from the repository secrets `TD_API_ID` and `TD_API_HASH`; forks build without
  them.

## Build and run

```sh
xcodegen generate
open Memvo.xcodeproj        # schemes: Memvo (iOS), MemvoMac
```

From the command line (everything goes to `build/`, which is ignored):

```sh
Scripts/build.sh ios               # iOS app for the simulator (Debug); add Release to check release builds
Scripts/build.sh mac               # Mac app
Scripts/build.sh test              # core unit tests, a few seconds
Scripts/build.sh uitest            # iOS UI tests on the newest iPhone simulator (slow)
```

The first build downloads TDLib (about 350 MB) and compiles TDLibKit, which takes a while; later builds are fast.

### On your iPhone

Set your team in Xcode (Signing & Capabilities) or pass `DEVELOPMENT_TEAM=<team id>` to `xcodebuild`, pick your
iPhone and Run. A free Apple ID works; its builds expire after 7 days. Sign the Mac app with the same Apple
Development identity every time: an ad-hoc signature changes on every build, which loses Keychain access and forces a
new Telegram sign-in.

### Test hooks (Debug builds only)

Release builds ignore all of these.

| Launch argument | Does |
|---|---|
| `-UITestReset` | Wipes settings and the Keychain on launch |
| `-UITestDemoLibrary` (`-UITestDemoCount N`) | Replaces the library with N demo items (default 300), no Telegram needed |
| `-autoScrollTest` | Scroll benchmark of the grid, results in the log |
| `-verifyCloudReads`, `-verifyCloudReadsName <file>`, `-verifyCloudReadsFull` | Reads backed-up videos through the player's code path and logs failures |
| `-clearCacheTest` | Clears every cache on launch and logs the sizes |

The Mac Debug build also listens for `DistributedNotificationCenter` commands to snapshot and drive the window
(`macOS/App/DebugHooks.swift`).

## Tests

- **Core unit tests** (`Packages/MemvoCore/Tests`): caption format and its cross-platform test vectors
  (`docs/test-vectors/format1.json`), random-access decryption, split files, job state machine, slow-down parsing,
  de-duplication, restore linking, cache. Add tests here for any logic change.
- **UI tests** (`UITests/`): first launch, the demo library grid (open viewer, select, swipe to select, pinch, scroll,
  date scrubber). Screenshots go to the test results and to `CG_SCREENSHOT_DIR` when set
  (`TEST_RUNNER_CG_SCREENSHOT_DIR=/tmp/shots Scripts/build.sh uitest`).
- **On a device**, with a real account, before a release: sign in, back up a few photos and a video over 2 GB if you
  can, view and stream them, restore after a reinstall, try an encrypted library. The checklist is in
  [RELEASING.md](RELEASING.md).

## Logs

Settings → Logs shows the app's own log; Debug builds also print it to the console. Every line goes through
`Redactor` (phone numbers, keys, channel IDs and file IDs removed). Never log photo contents, passphrases or keys.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and push to `main`: core unit tests, iOS and Mac builds (Debug
and Release) with warnings treated as errors in our code, and the UI tests. Releases are built by
`release.yml`; see [RELEASING.md](RELEASING.md).
