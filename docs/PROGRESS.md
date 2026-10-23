# Progress and handoff

Read this first when resuming. **Priority: iOS.** Android is paused at the owner's request (2026-10-23).

## Status

| Phase | Scope | Status |
|---|---|---|
| v1.0.0 | iOS app on Bot API, CI, unsigned IPA | ✅ Released (superseded) |
| 0 | Research: issues, architecture, cloud format | ✅ Done |
| 1 | iOS on TDLib (user account), format 1 | ✅ Built, CI green; **needs on-device testing** |
| 3 (iOS part) | Core unit tests, UI smoke tests, no force-unwraps | ✅ Done |
| 4 (iOS part) | CI on macos-latest + xcode-27, IPA, tag release | ✅ (v2.0.0-beta.1) |
| 2 | Android on TDLib | ⏸ Paused. Only `android/tdlib.version` and a manual `tdlib-android.yml` workflow exist |

## iOS: done

- TDLib login (api_id/api_hash, phone, code, 2FA), re-sign-in if the session ends
- Library: create "CloudGallery Library" (plain or E2E) or pick a channel; header pinned + in description
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

## iOS: not done / known gaps

- 720p preview copies for instant cloud playback are designed but not built.
- "Smooth streaming copies" (1080p preview for > 500 MB videos) is not implemented.
- One-time import of 1.0 (Bot API) uploads is not implemented; 1.0 files stay in the old channel.
- Uploads can't run as iOS background transfers (MTProto); they run in-app, in continued-processing (iOS 26+), overnight while charging, or for ~25 s per Shortcut.
- No dedicated performance profiling on 50k+ items yet.

## How to verify locally

- Core tests: `cd ios/CloudGalleryCore && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
- TDLib layer typecheck: a scratch SwiftPM package that symlinks `ios/CloudGallery/Services/Telegram/*.swift` plus `KeychainStore.swift` and `AppLog.swift`, depends on a local TDLibKit checkout with TDLibFramework as a local binary target (download `TDLibFramework.zip` from Swiftgram releases with curl).
- Full app builds only in CI (`.github/workflows/ios.yml`).
