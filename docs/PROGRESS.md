# Progress and handoff

Read this first when resuming. Scope: the iOS and Mac apps. Android isn't part of this repository
([not-planned.md](not-planned.md)).

## Status

| Phase | Scope | Status |
|---|---|---|
| v1.0.0 | iOS app on Bot API, CI, unsigned IPA | ✅ Released (superseded) |
| 1 | iOS on TDLib (user account), format 1 | ✅ Device-tested |
| Mac 1 | macOS app (SwiftUI, shares the services) | ✅ Built, owner testing |
| Repo | Standalone GPL-3.0 repository: only the owner's commits, `iOS/` `macOS/` `Shared/` `Packages/`, CLA, issue forms, approved-issue gate, CI, CodeRabbit, docs | ✅ 2026-10-24, local; not pushed yet |
| App Store | [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md): name and icon, reviewer demo mode, listing | ⏳ Next |
| Mac 2 | WhatsApp backup via Mac (iPhone backup → WhatsApp only → encrypted → Telegram) | ⏳ Research first |

## iOS: done

- TDLib login (api_id/api_hash, phone, code, 2FA), re-sign-in if the session ends
- Library: create "Memvo Library" (plain or E2E) or pick a channel; header pinned + in description
- Restore by scanning channel history (no index file); incremental scan before each backup run
- Backup engine: persistent queue (pending → uploading → verified/failed), 2 lanes, FLOOD_WAIT pause, SHA-256 dedupe, per-part size verification and checkpoints, split > 2/4 GB, Live Photos, thumbnails (document thumbnail, or encrypted `t` resource for E2E)
- Selection: media type, screenshots, albums include/exclude, date-from, Wi-Fi only, charging only
- Streaming video: AVAssetResourceLoader over TDLib ranged reads, split + chunk decryption, prefetch of neighbours, AVPlayerViewController (PiP, AirPlay, speed)
- Gallery: unified timeline (day/month/year), pinch, date scrubber, Albums tab, drag-to-select, share/save/delete from cloud/delete from iPhone, info panel (codec, HDR, map)
- Caches: thumbnails (300 MB), viewed media (1 GB), TDLib `optimizeStorage`, usage + Clear in Settings
- Free Up Space (off by default) with TDLib verification; App Intents; BGProcessingTask; BGContinuedProcessingTask (iOS 26+)
- Tests: 64 core unit tests (format, vectors, random-access crypto, split mapping, job machine, FLOOD_WAIT, dedupe, cache), UI smoke tests

## iOS: device-tested fixes (v2.0.0-beta.4, 2026-10-23)

- Tested on a real iPhone with a real account (local Xcode 27.1 + devicectl; see live console / `-verifyCloudReads*` self-tests).
- Item ids lowercase (scan duplicates + false "not found" failures fixed; store repairs old data on open).
- Store notifications async (deadlock/watchdog kill on Failed/Retry fixed).
- Streaming: one continuous TDLib download window, stale-local-copy recovery (uploaded temp copies / moved containers), unique URL per player, neighbour prefetch shares the window, 30 s stuck timeout with diagnostics.
- TDLib client start serialised (two clients raced on td.binlog).
- Reinstall: restored items re-link to photos (caption `l` asset id, else name + second + size; `RestoreLinker`, unit-tested).
- UI: Photos-style grid (single scrubber, zoom transition, cancellable thumbnails), Albums media types, viewer with custom video controls (⋯ speed/PiP/AirPlay, zoom), clear backup badges + legend, Backup complete state, redesigned onboarding, Libraries screen (switch / rename / create) in Settings.
- Back up chosen photos; "Back up new photos automatically" toggle.
- beta.5/6: nothing uploads on its own (Back up now = everything, Back up = chosen); edited versions backed up (role `e`) and re-uploaded when edited after backup; Duplicates review (Telegram copies, same content twice, identical iPhone copies); Download a copy of the library to Files; Telegram inactivity deletion set to 2 years from Settings; local index excluded from device backups; plain-language Free up space.

## macOS app (2026-10-24)

- Target `MemvoMac` in `project.yml` (macOS 15+). Compiles `Shared/` (services, sign-in, settings, backup screens) plus the Mac-only UI in `macOS/`.
- Not sandboxed (hardened runtime + Photos entitlement); data in `~/Library/Application Support/com.shahil-kv.memvo.mac` and `~/Library/Caches/com.shahil-kv.memvo.mac` (`AppPaths`).
- Sign with the Apple Development identity (team 47PTVGK8BJ): ad-hoc builds change identity every build and lose keychain access to the TDLib key (forces a new Telegram login).
- UI: Apple Photos-style sidebar (Library, Favorites, Videos, Live Photos, Not Backed Up, Only in Cloud, Backup, Media Types, Albums) with a backup status card; grid with zoom slider, click to open, Select mode (or ⌘/⇧-click), arrow keys, context menus, drag to Finder, ⌘I inspector; viewer with hero zoom from the tile, ← → / two-finger swipe, pinch / double-click zoom, AVPlayerView (PiP, AirPlay), Live Photo on LIVE hover; Backup page; Settings (⌘,); menu bar status.
- Performance (2026-10-24): Mac grid is `MacPhotoGrid` (NSCollectionView, recycled layer-drawn tiles, prefetching, diffable data source); shared `ThumbnailPipeline` (memory cache, low-res→sharp, loading ahead via the same PHCachingImageManager, cancel when scrolled away) used by both apps; iOS uses `GridPrefetcher` + cached filtered timelines; `GalleryModel` reloads throttled and skipped when nothing changed. Mac `scrolltest`: whole library in 4 s, warm avg 8.4 ms/frame, no frame > 33 ms.
- iPhone grid (2026-10-24): `NativePhotoGrid` (UICollectionView) replaced the SwiftUI LazyVGrid after a simulator benchmark (`-autoScrollTest`, `ScrollBenchmark`): SwiftUI fell to ~7 fps at 10k items and froze at 50k (1.3 GB); native holds 60 fps at 50k (244 MB). Keeps every custom feature: badges, durations, pinch columns with day/month/year regrouping, tap → viewer with the iOS 18 zoom transition (UIHostingController + preferredTransition), long-press to select, Photos' swipe-to-select, selection bar, date scrubber. UI tests: `NativeGridTests` (screenshots to `TEST_RUNNER_CG_SCREENSHOT_DIR`).
- Library switching: saved per-library index (`LibrarySnapshots`) → 0.13 s, background re-scan; `PhotoAvailability` probe so PhotoKit never blocks (a Mac without a Photos library made every call wait ~30 s); thumbnails by remote id (`ThumbnailIdStore`).
- Debug builds: `DebugHooks` snapshot / drive the window via distributed notifications (no Screen Recording permission needed).
- Build: `Scripts/build.sh mac Release`, or `xcodebuild -project Memvo.xcodeproj -scheme MemvoMac -configuration Release -derivedDataPath build/DerivedData DEVELOPMENT_TEAM=<team> CODE_SIGN_IDENTITY="Apple Development" build`, then copy `build/DerivedData/Build/Products/Release/Memvo.app` to /Applications.

## iOS: not done / known gaps

- 720p preview copies for instant cloud playback are designed but not built.
- "Smooth streaming copies" (1080p preview for > 500 MB videos) is not implemented.
- One-time import of 1.0 (Bot API) uploads is not implemented; 1.0 files stay in the old channel.
- Uploads can't run as iOS background transfers (MTProto); they run in-app, in continued-processing (iOS 26+), overnight while charging, or for ~25 s per Shortcut.
- No dedicated performance profiling on 50k+ items yet.

## How to verify locally

- Everything: [DEVELOPMENT.md](DEVELOPMENT.md) (`Scripts/build.sh test|ios|mac|uitest`).
- CI: `.github/workflows/ci.yml` on every pull request; releases: `release.yml` (Actions → Release button; versions restart at 0.1.0).
