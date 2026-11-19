# Sync, local/remote index, restore, dedupe and counts: Lelvo vs Ente vs Immich

Date: 2026-11-18. Read-only comparison, no source changed.

Method note. GitHub search was rate limited (30/min, then 403) and the Ente repo moved to `ente/ente`, so Ente issues could not be mined. For Ente the fixes are read from the explanatory comments in its code, which record past bugs. Immich issues were read directly. Anything resting on that is marked "unverified".

## How Ente does it

Server diff model. `remote_sync_service.dart` pulls a per-collection diff from the server (`diff_fetcher.dart`), then maps device files to uploaded rows. The mapping rules encode many past bugs:
- First sync pulls the diff before marking uploads, or remote files get queued again (`remote_sync_service.dart:146-147`).
- Re-enabling a backup folder must not duplicate rows (`:488`).
- A diff can hold two uploads of one local file, so a local row is claimed only once (`:863`).
- Do not keep a remote localID with no matching local file (`:916`).
- iOS edits are not detected by modification time (it changes for other reasons, and reading adjustments can pull from iCloud), so edits made between installs can be missed (`:923-926`, accepted loss).
- Local sync must not race downloads, or it creates wrong rows (`local_sync_service.dart:104`).
- An iOS "source file missing" error is not persisted as an ignore, because iCloud may supply the asset later (`local_sync_service.dart:314`). Other unreadable files go to an ignore list with a reason (`ignoreUpload`).
- After a mapping repair, a follow-up remote sync is still needed (`:301`).

Dedupe by content hash. `existing_upload_resolver.dart:67-150` looks up uploaded files by hash, file type and owner. Resolution order matters: same local ID and collection (drop the pending row), then an uploaded row with no local ID (adopt this local ID), then same local ID in another collection (link, no upload), else upload. It refuses to remap an already-uploaded row (`:75-80`). Trash has its own service (`trash_sync_service.dart`).

## How Immich does it

Local side. `local_sync.service.dart` keeps a local-asset DB per device album and syncs it in two steps:
- A fast path (`checkAddition`, `:219`) when album count and updated-time show additions only.
- A full sorted diff (`fullDiff`, `:263`) otherwise, with a custom equality check that avoids comparing checksums (`:299`).
- Android must sync all albums because deletions cannot be detected natively (`:81`). iOS cloud albums always full-sync (`:95`).
- Trashed local assets are processed separately (`:358`).

Hashing. `hash.service.dart` hashes only assets that are missing a hash, in batches (`:104-123`). Network access is allowed only for explicitly selected albums (`:124-128`). It can be cancelled between batches, and hashes are migrated from a cloud ID to the local ID so a reinstall does not re-hash (`:46`). Trashed assets on Android are hashed too (`:62`).

Remote side. `sync_stream.service.dart` applies a server event stream. Dedupe is by checksum on the server.

Real failures from issues:
- #22248 and #20331: hashes lost or album re-selected, so the app wants to re-upload tens of thousands of assets.
- #29542: iOS re-uploads degraded or corrupted copies with different checksums, up to 142 copies of one video, so dedup never converges.
- #32939: the background uploader re-uploads everything on each backgrounding (750 GB in a morning).
- #30458: assets that cannot be read (PHPhotosErrorDomain 3169, for example iCloud Shared Album husks) retry forever, and nothing can clear them.
- #24982: an unavailable source looked like "all deleted", so everything went to trash.
- #32294: a trash request was sent for an unrelated asset during sync.
- #22015 (cited in a maintainer reply on #32294): the server trash call happens before the device confirmation dialog.

## How Lelvo does it

The Telegram channel is the truth. The index is a cache rebuilt by `LibraryService.scan` (`Shared/Services/Telegram/LibraryService.swift:423-560`; Android `android/data/.../LibraryScanner.kt`).
- Single-flight gate: only one scan runs at a time, and a full scan that finished while a request waited is reused (`:423-436`).
- Recent scans stop at the last message id. Full scans read everything. A new device or reinstall with an empty index restores from an index snapshot, then runs a full scan in the background (`:448`, `:518-530`).
- Live updates: a channel `.added` event triggers a debounced recent scan, and `.deleted` events trigger `applyDeletes` (`:784-850`).
- Cross-device Recently Deleted and favorites/albums go through note messages (`TrashLog`, `MetaLog`).

Dedupe is two-stage (`Packages/LelvoCore/.../Backup/Deduplicator.swift:4-6,21-47`). It first checks the PhotoKit local id, then SHA-256 of the exported original, so it survives reinstall and new devices. Edits count: a cropped copy is not a duplicate (`isSamePhoto`, `:49-55`). Hashes are reused on retry only if the modification date and sizes are unchanged (`canReuseHashes`, `:57-67`). Android has the same logic (`BackupEngine.kt:674-698`).

Restore. `RestoreLinker` (`Index/RestoreLinker.swift:20-40`; Android `core/.../index/RestoreLinker.kt`) links restored items to existing phone photos without reading files: first by the asset id in the caption, then filename + capture second + pixel size, each linked once. `keepingLocalState` stops a rescan from erasing dates and queue state (`Backup/EditCheck.swift:27-40`).

Counts come from one pure function used by all screens (`Backup/BackupCounts.swift:22-40`; Android `core/.../backup/Uploads.kt:134-210`). `removedFromBackup` keeps on-purpose removals out of "left to do" (`:49-55`). `PhotoChangeScan` uses Photos' change history with a weekly full read and a guard so a Photos hiccup does not drop 50 queued items (`PhotoChangeScan.swift:7-34`, `canUseChanges`, `queuedButDeleted`).

Delete from phone (`Shared/Services/FreeUpSpaceService.swift:78-105`) re-reads the cloud state first, requires a fresh verification of every part by message id and size, refuses items with edits the cloud lacks (`EditCheck.mayLoseEdit`), and checks that the photo is really gone after deleting. Retries stop at `maxAttempts = 5` (`JobQueue.swift:39`).

## Case table

| Case | Ente | Immich | Lelvo has it? | Verdict | Effort | Platforms |
|---|---|---|---|---|---|---|
| Hash dedupe across reinstall/new device | Hash + owner lookup, 4-way resolution (`existing_upload_resolver.dart:67`) | Server checksum; local hash DB, hash migration (#22248 shows failure) | Yes, id then SHA-256, link/adopt (`Deduplicator.swift:27-47`) | ALREADY BETTER | none | all |
| Relink restored items to phone photos without re-reading | Match by localID/hash | Hash reconcile from cloud ID | Yes, caption id then name+date+size (`RestoreLinker.swift:20`) | ALREADY BETTER | none | all |
| Crop/edit of an already-backed-up photo is not a duplicate | Not handled (iOS edits missed, `remote_sync_service.dart:923`) | Not handled | Yes, `isSamePhoto`, `EditCheck` | ALREADY BETTER | none | all |
| Scan only new items, not whole library | Server diff cursor | Album count/updated-time fast path (`local_sync.service.dart:219`) | Yes: recent scan by message id, change history, snapshot (`LibraryService.swift:441-448`) | ALREADY BETTER | none | all |
| Whole-library DB read in automatic scan | Not applicable | Targeted queries | No. `store.allItems()` on every scan: `:937` (each live scan), `:448`, `:829`, `:881`; Android `LibraryScanner.kt:203,460` | ADOPT: load only the ids the scan touched | M | iOS, Mac, Android |
| Full scan ended early (empty page, nonzero next) must not mark items vanished | Not applicable | Not applicable | Risk: `break` on an empty page (`:501`; Android `LibraryScanner.kt:150`) leads to "Not found in the channel" and re-upload (`:963-972`). Unverified that TDLib can return such a page | ADOPT: confirm via `existingMessages` before flipping to failed | S/M | all |
| Concurrent scans | Collision guards | Cancellation tokens | Yes, scan gate (`:423`) | ALREADY BETTER | none | all |
| Source unavailable looks like "all deleted" | Not applicable | #24982: mass trash, maintainers say working as intended | Yes, `queuedButDeleted` guard (`PhotoChangeScan.swift:22`) | ALREADY BETTER | none | all |
| Limited photo access | Handles picker close (`local_sync_service.dart:498`) | n/a | Yes: shown as Limited/Partial (`BackupDashboardView.swift:256`, `PhotoAccess.kt:63`) | ALREADY BETTER | none | all |
| Unreadable asset retries forever | Ignore list with reason; iOS source-missing not persisted | #30458: retries forever, cannot clear | Partial: stops after 5 tries, shows in Failed, but Retry re-queues the same photo and the Failed count never settles. Unverified whether a "skip this photo" exists | ADOPT: ignore-with-reason per local id, auto-cleared when the photo changes | M | all |
| iCloud-only originals: network only when allowed | Not persisted as failed | Network only for selected albums (`hash.service.dart:124`); #20408 storage blow-up | Yes, `isNetworkAccessAllowed` per path (`PhotoLibraryService.swift:552`) | SKIP | none | iOS, Mac |
| Re-upload loops from non-deterministic export (different bytes each time) | Hash resolver | #29542: 142 copies, #32939: 750 GB | Mostly guarded: hash is of exported bytes, `canReuseHashes`, 5-attempt cap. Nothing that detects the same asset exporting different hashes twice | ADOPT: after 2 different hashes for one local id, stop and flag the item | S | all |
| Counts (backed up / on device / cloud only) | Derived per view | #28392 album count mismatch, #22248 wrong remainder | One shared pure function, tests (`BackupCounts.swift:22`, iOS+Android) | ALREADY BETTER | none | all |
| Delete local copy only after verification | Local delete after upload ok | Trash server asset before device prompt (#22015, #31627) | Yes, re-verifies every part by id+size, edit check, post-check (`FreeUpSpaceService.swift:78-99`) | ALREADY BETTER | none | all |
| Cross-device trash/favorites | Server | Server stream | Yes, notes + full-scan reconcile | ALREADY BETTER | none | all |
| First sync before queueing uploads | Yes (`remote_sync_service.dart:146`) | Hash DB first | Yes: scan precedes upload resume (`LibraryService.swift:418`) | ALREADY BETTER | none | all |
| Re-enabling a folder must not duplicate | Yes (`:488`) | Re-selecting album re-uploads (#20331) | Covered by id + hash lookup | SKIP | none | all |
| Two uploads of one local file in a diff | Claim once (`:863`) | n/a | Duplicate messages reported in scan and removable (`LibraryService.swift:978`) | SKIP | none | all |
| Hash cancellation between batches | n/a | Yes (`hash.service.dart:34,56`) | Not verified in the backup hashing loop | Unverified, check | S | all |
| Android: trash detection not native | n/a | Syncs all albums each time (`local_sync.service.dart:81`) | Android uses MediaStore generation or date? Unverified | Unverified, check | S | Android |

## Notes

- Lelvo already beats both on counts, verified delete and edit safety. The remaining risk sits in scan edge cases at 40k scale and in stuck Failed items.
- Ente's rule "do not persist an iCloud-unavailable failure" matches how Lelvo should treat an asset that is not downloaded yet.
