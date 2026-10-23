# Progress and handoff

Read this first when resuming. Each phase ends with CI green and an installable build.

## Status

| Phase | Scope | Status |
|---|---|---|
| v1.0.0 | iOS app on Bot API (`ios/`), CI, unsigned IPA | ✅ Released |
| 0 | Research: issues, architecture, cloud format | ✅ Done |
| 1 | iOS on TDLib (user account) with format 1 | ⏳ In progress |
| 2 | Android on TDLib, Room queue, WorkManager FG, Media3 | ⬜ Not started |
| 3 | Quality gates: tests both platforms, UI smoke tests, warnings | ⬜ |
| 4 | Android CI + signed APK, v2.0.0 release with IPA + APK | ⬜ |

## Phase 1 checklist (iOS)

- [ ] Core: format-1 caption codec (plain + encrypted), E2E key derivation (600k, key check), CGFE random-access reader, split-part range mapping, job-queue state machine, FLOOD_WAIT parsing, test vectors
- [ ] TDLibKit integrated; CI builds with it
- [ ] Login: api_id/api_hash entry, phone, code, 2FA, logout
- [ ] Library: create "CloudGallery Library" or pick a channel; header read/write
- [ ] Backup engine on TDLib: queue states, verify by size, dedupe, split > limit, Live Photos, thumbnails, selection filters (albums, screenshots, photos/videos only, date range, Wi-Fi, charging)
- [ ] Restore by scanning channel history
- [ ] Streaming video: AVAssetResourceLoader over TDLib ranges, split + decrypt, PiP, AirPlay, speed
- [ ] Photos: progressive load, cache caps (300 MB / 1 GB) + TDLib optimizeStorage
- [ ] Timeline year/month/day + date scrubber, Albums tab, drag-to-select
- [ ] Free Up Space on TDLib verification
- [ ] App Intents, BGContinuedProcessingTask, BGProcessingTask on TDLib
- [ ] Docs: ios/README.md for TDLib login + SideStore

## Known limitations right now
- The released 1.0.0 IPA uses the Bot API (50 MB upload / 20 MB view limits).

## How to verify locally (no Xcode on this machine)
- Core tests: `cd ios/CloudGalleryCore && swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
- Full app builds only in CI (`.github/workflows/ios.yml`, lanes `macos-latest` and `xcode-27`).
