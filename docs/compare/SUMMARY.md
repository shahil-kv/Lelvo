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

## Status (2026-11-18, nothing committed yet, nothing run on a device)

| Item | State |
|---|---|
| 1 Halt on session ended / channel unusable | Written on iPhone, Mac, Android. Classifier tested (`RunStopTests`, `RunStopTest`). Engine wiring compiled only. |
| 2 Halt on OS disk-full | Written. Stops the run only when under 200 MB is free; one huge file that doesn't fit fails alone, so photos behind it still upload. |
| 3 Vanished-items guard | Written. `ScanPaging` (tested) follows TDLib's end signal; a scan that stops early marks nothing missing and does not mark the index repaired. |
| 4 Ignore list for unreadable photos | Not started. Needs a stored field on each item; held back to avoid a schema change for the 5 current users. Retry still resets the attempt count. |
| 5 Export returns the true original | Audited, no change needed: `PHAssetResourceManager` writes the unedited `.photo` bytes; RAW alternates and edit data go as extra parts. |
| 6 iCloud progress and temp cleanup | Not started. |
| 7 Whole-library reads | Recent-scan merge now reads only touched items (iPhone, Mac, Android). Still whole-library on each backup run: `relinkRestoredItems` (`BackupEngine.swift:468`) and `writeSnapshotIfDue` (`LibraryService.swift:890`); not measured. |
| 8 Android drag-select | Done: index built once per drag, repeat tiles skipped. |
| 9 Mac memory trim | Done: memory-pressure source trims the same caches as iPhone. |
| 10 Hash cancellation | Not checked. |

### Tier 3 status (2026-11-18, built on all three, not run on a device, no database changes)

| Item | State |
|---|---|
| 11 Retry on viewer errors | Done: "Try again" on iPhone, Mac and Android (photo and video). On iPhone and Mac it also shows for "can't be previewed" and "not fully in your library yet", where it just shows the same message again. |
| 12 Player failure fallback | Done on iPhone and Mac: a failed video reopens once on its own, a second failure shows "Try again" (no loop). Android already surfaced the error; its Try again calls `prepare()` again. Not done: switching a failed original to the fast version automatically. |
| 15 Android drag haptic | Done (tick per tile). Mac marquee select not done: it is a new capability. |
| 16 Android keep-screen-on | Done. HDR colour mode not done (needs a device with an HDR clip). Loop-video setting and download ring not done: new settings and UI. |
| 17 Live swipe check | Audited, no bug: Live plays only on long press or the chip and resets when the page leaves. |
| 13 Jump to date, 14 scrubber ticks, idle fade, per-month haptic | Not done: new UI, preview and approval first. |
| ThumbHash | Not done: needs an approved issue (caption format). |

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
| Not done | Apple `prefetchCount` wiring, Android scroll benchmark, local-index date index and lighter full reload (needs a local migration), ignore-list table. |

## Ignore list and ThumbHash write path (2026-11-18, later; built on all three, tested at logic level, nothing committed)

| Piece | State |
|---|---|
| Ignore-list table | Done. iPhone/Mac schema 7 to 8, Android Room 4 to 5, one new table each (`ignored_assets`), nothing else changed. A test upgrades a real version-7 file with items; the new Android build was installed over the emulator's live version-4 database (36 items) and opened with all items intact and the table present. |
| Ignore-list behaviour | Done: a photo with no original file is set aside when it fails; Retry skips it until the photo changes; it stays under Failed with its reason; the "retryable" count leaves it out. Only that one definite case is set aside (other failures, which may be temporary, keep today's behaviour). No new screen. Android's store lookup has no JVM test (Room). |
| ThumbHash write path | Written on both, behind an off switch (`ThumbHashRollout.writesToCaptions`, `ThumbHash.WRITES_TO_CAPTIONS`). With the switch off, uploads are byte-for-byte as before. The glue that makes a hash from the upload's thumbnail (`ThumbHashMaker`) has no automated test; verify it on the "Android test" library when switching on. |
| Placeholder drawing | Written on iPhone, Mac and Android: shown only for cloud-only tiles that have a hash and no thumbnail yet; inert today because no item has a hash. Not seen on screen. |
| Switching on | Not done: wait until every user has this build, then turn the switch on, upload one test photo, check the caption has `th`, then plan the paced backfill. |
