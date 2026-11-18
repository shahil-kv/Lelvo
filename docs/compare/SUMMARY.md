# Ente / Immich comparison: ranked adopt list (2026-11-18)

**Full feature map (every shipped area: how they do it, what we have, what is missing, better-than-them bar):**
[feature-improvement-matrix.md](feature-improvement-matrix.md).

Sources: [upload-and-retry](upload-and-retry.md), [sync-and-restore](sync-and-restore.md),
[gallery-and-grid](gallery-and-grid.md), [viewer-and-video](viewer-and-video.md).
Evidence is thin: GitHub search was rate-limited, Ente issues were not searchable, clones were shallow. Items marked
"verify" are grep-only. Nothing here has been run on a device.

Where Lelvo is already ahead: counts (one shared function), verified Free Up Space, edit-safe dedupe, relink after
reinstall, snapshot restore, native grids (iOS, Mac), pinch, swipe-select, thumbnail cache, streaming, seek, preload,
quality fallback, exact FLOOD_WAIT.

## Status (2026-11-18, updated later the same day)

| Item | State |
|---|---|
| 1 Halt on session ended / channel unusable | Written on iPhone, Mac, Android. Classifier tested (`RunStopTests`, `RunStopTest`). |
| 2 Halt on OS disk-full | Written. Stops the run only when under 200 MB is free; one huge file that doesn't fit fails alone. |
| 3 Vanished-items guard | Written. `ScanPaging` (tested) follows TDLib's end signal. |
| 4 Ignore list for unreadable photos | Done in store + engine. Skipped photos screen added (Backup tab). |
| 5 Export returns the true original | Audited, no change needed. |
| 6 iCloud progress and temp cleanup | Temp cleanup audited (defer). Download progress for iCloud-only photos not started. |
| 7 Whole-library reads | Recent-scan merge reads only touched items. Still whole-library on some backup paths; not measured. |
| 8 Android drag-select | Done: index built once per drag. |
| 9 Mac memory trim | Done. |
| 10 Hash cancellation | Done (`72a5e56`): checks every 1 MB chunk on iPhone, Mac and Android. |

### Tier 3 status (2026-11-18, updated later)

| Item | State |
|---|---|
| 11 Retry on viewer errors | Done on iPhone, Mac and Android. |
| 12 Player failure fallback | Done on iPhone and Mac. Not done: auto-switch failed original to fast version. |
| 15 Android drag haptic; Mac marquee | Done (marquee wired in `MacPhotoGrid`). |
| 16 Loop videos; keep-screen-on; download ring | Loop videos done (all three). Android keep-screen-on done. Download ring done on iPhone, Mac and Android (`VideoDownloadRing` / Exo buffer). |
| 17 Live swipe check | Audited, no bug. |
| 13 Jump to date; 14 scrubber ticks | Scrubber year ticks exist. Jump to date done on iPhone, Mac and Android (sheet → scrubber fraction / date index). Date index on Apple is schema 8→9 (`fa494f4`); Android already indexed `created_at`. |
| ThumbHash | Maths + optional `th` + makers + placeholder drawing done. Writes stay **off** until every user has this build. **Backfill dropped** (not worth it at 100k edits). |

## Tier 1: data trust (fix first, all three platforms, with unit tests)

| # | Item | Where | Effort |
|---|---|---|---|
| 1 | Halt the run on revoked session, channel gone, no write rights; show a sign-in banner | `BackupEngine.swift:1584`, `:654`; `BackupEngine.kt:1014` | S/M |
| 2 | Halt on OS disk-full (ENOSPC / `NSFileWriteOutOfSpaceError`) instead of 5 retries per file | `BackupEngine.swift:1577`; `BackupEngine.kt:1002` | S |
| 3 | Confirm "vanished" items with `existingMessages` before flipping them to failed (premise unverified: can `searchChatMessages` return an empty page with a non-zero next id?) | `LibraryService.swift:501`, `:963-972`; `LibraryScanner.kt:150` | S/M |
| 4 | Per-photo ignore list with reason, cleared when the photo changes; Retry stops resetting unreadable assets | `BackupEngine.swift:793`, `JobQueue.swift:39` | M |
| 5 | Flag an item when one local id exports two different hashes (re-upload loop) | `Deduplicator.swift:57-67` | S |
| 6 | Audit that iOS export returns the true original (ProRAW, edits) | `PhotoLibraryService.swift:526` | S |

## Tier 2: performance at 40k

| # | Item | Where | Effort |
|---|---|---|---|
| 7 | No whole-library reads on automatic paths: load only touched ids | `LibraryService.swift:448,829,881,937`; `LibraryScanner.kt:203,460`; `BackupEngine.swift:548` | M |
| 8 | Android drag-select is O(n) per pointer move | `Selection.kt:104-124` | S |
| 9 | Mac memory-warning cache trim (thumbnail cache up to 400 MB) | `ThumbnailPipeline`; iOS has it at `LelvoApp.swift:16` | S |
| 10 | Hash cancellation between batches (verify we lack it) | backup hashing loop | S |

## Tier 3: UX polish

| # | Item | Effort |
|---|---|---|
| 11 | Retry button on viewer error states (iOS `ViewerView.swift:466`, Android `ViewerPages.kt:236`, Mac unchecked) | S |
| 12 | iOS/Mac player failure falls back to the fast version instead of a black screen (`ViewerView.swift:1330`) | M |
| 13 | Jump-to-date picker | M |
| 14 | Year ticks on scrubber for long libraries; idle fade; per-month haptic | M |
| 15 | Android per-tile drag haptic; Mac marquee select | S / M |
| 16 | Loop-video setting; Android keep-screen-on and HDR colour mode (verify); cloud-video download ring | S each |
| 17 | Verify Live/Motion Photo playback when swiping onto it (Immich #14758) | S |

## Needs a format change (approved issue first)

- ThumbHash placeholder for cloud-only tiles (caption format bump).

## Skip

Filmstrip, panorama viewer, OCR/QR search, server-side transcoding.

## Still to check

Whether App Intents run out-of-process (shared `running` flag); Android stall watchdog wiring; re-queue after an
upgrade or a Telegram-side delete (Immich #20331, #14165); iCloud download progress and temp-file cleanup.
Not yet compared: sign-in and onboarding, settings, albums and search, share and trash, Google Photos UX matrix.

## Quality bars (from a second agent, 2026-11-18)

Canonical full list (Ente / Immich / Lelvo / missing / bar / checklist):
[feature-improvement-matrix.md](feature-improvement-matrix.md).

The short tables below are a summary. The "their weak spot" column was agent opinion about Ente and Immich and was not
verified in every row. The "your bar" column is an acceptance list. "Evidence" says what the code comparison above
already shows.

### Trust

| Area | Bar | Evidence |
|---|---|---|
| Backup failures | Plain reason and one correct next step; never a false "done"; never stranded forever | Tier 1 items 1-5 close the "stranded" part |
| Auto / background backup | Honest blockers with a Fix button; resume after kill; backlog drains | `RunHeartbeat` exists; App Intents process question open |
| Free Up Space | Delete only after a fresh Telegram size check; cancel deletes nothing | Already verified in `FreeUpSpaceService` (sync report) |
| Counts / Backup tab | Green only when verified; waiting, failed, removed, limited access, FLOOD shown | One shared count function (sync report) |
| Sign-in / session recovery | Re-sign-in is clear; library and queue intact; no hang | Tier 1 item 1 adds the banner |
| Restore / new device | Unlock, scan, relink; no re-upload of what is already there | `RestoreLinker` exists; Tier 1 item 3 guards the scan |
| Encryption unlock | Clear recovery key; wrong key refuses without a wipe; Passwords autofill | Not checked yet |

### Daily feel

| Area | Bar | Evidence |
|---|---|---|
| Grid | 60 fps at large libraries, scrubber keeps up, truthful badges | Ahead on iPhone and Mac; Android drag-select is Tier 2 item 8 |
| Viewer | Photos-like pager; Live every time; sound stops on close; resume mid-video | Live swipe check is Tier 3 item 17; rest not checked |
| Video | Fast version, stall fallback, seek that works | Ahead; player-failure fallback is Tier 3 item 12 |
| Albums, favorites | Same on every device; drop "beta" once solid | Not compared yet |
| Multi-device notes | Favorite, album, trash show up reliably; kill mid-sync is safe | Not compared yet |
| Recently Deleted | Same days-left everywhere; recover on any device | Not compared yet |
| Offline / cache | Cached items open offline; caps and Clear are obvious | Not compared yet |

### Migrate and round-trip

| Area | Bar | Evidence |
|---|---|---|
| Takeout import | Kill mid-zip resumes; zero re-uploads; every skip explained | Built, never run on a device with a real Takeout |
| Save to Photos | Original bytes plus date, place, albums, favorites | Not checked |
| Download a copy / second copy | Resumable; pause if the drive is gone; never the only copy | Not checked |
| Duplicates | Exact free-space number; "Select extras"; trash, not a silent wipe | Not checked |

### Lower urgency

Search (results appear as the index fills; no silent holes for iCloud-optimized photos), Map (smooth clusters), Memories
(never dead-ends), Onboarding (first photo is safe; "welcome back" is instant), Settings and storage ("why is cache big"
and Clear has an obvious effect), iOS, Android and Mac parity (one change fixes all three).

## ThumbHash and scroll performance (2026-11-18, later; built on all three, not run on a device, nothing committed)

| Piece | State |
|---|---|
| ThumbHash maths (Swift, Kotlin) | Done. Match the reference exactly on `docs/test-vectors/thumbhash1.json`; damaged hashes return nothing. Credit in `NOTICE.md` and both Acknowledgements screens. |
| Optional `th` caption field | Done on both: read, kept on items, dropped first when a caption is too long, never pushes albums out. Documented in `CLOUD_FORMAT.md`. Old readers ignore it (tested). **Nothing writes it yet.** |
| Hash on each item | Done with no migration: iPhone/Mac in the item's stored JSON, Android in the existing extras JSON column. Rows saved before it read as "none". |
| Drawing the placeholder, writing `th` for new uploads | Not started. Writing waits until readers have shipped to every user. |
| Fling deferral (iPhone, Mac) | Done: loads that haven't started wait while the grid flings faster than 3000 pt/s and resume below 1800; a watchdog releases them 0.2 s after scroll events stop. |
| Fling deferral + prefetch ahead (Android) | Done: same thresholds; prefetches about 2 screens ahead on Wi-Fi, at most 2 at once, inside the existing cap of 8 thumbnail downloads. |
| Date index | Done on Apple (schema 8→9). Android already had `created_at`. |
| Scroll measure | Debug Settings can load a 10k / 40k synthetic scroll library. `Scripts/android-jank.sh` exists. Blind Apple `prefetchCount` tuning held until a measured run. |
| Not done | Blind Apple prefetchCount change; ThumbHash writes still off. |

## Ignore list and ThumbHash write path (2026-11-18, updated later)

| Piece | State |
|---|---|
| Ignore-list table | Done. iPhone/Mac schema 7→8 then 8→9 (date index), Android Room; `ignored_assets`. |
| Ignore-list behaviour | Done: unreadable original is set aside; Retry skips until the photo changes; retryable count excludes it. |
| Skipped photos screen | Done on Backup tab (iPhone, Mac, Android): list reason, Try again / Try all again (unignore + enqueue). |
| ThumbHash write path | Behind off switch. **Backfill will not ship** (too many Telegram edits for a brief placeholder). New uploads only, after every user has a reader build. |
| Placeholder drawing | Written; inert until writes are on. |
| Switching on | Wait until every user has this build, then turn writes on for new uploads only. No backfill. |
