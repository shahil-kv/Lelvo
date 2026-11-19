# Feature improvement matrix: Lelvo vs Ente vs Immich

Date: 2026-11-18. Purpose: every **shipped** Lelvo feature, how Ente and Immich do the same job, what we are
missing, and the bar that would make us better — **without adding new product features** (no faces, no share
links, no web, no new Pro toys).

**How to use this file.** Work top-down. "Gap" means polish, reliability or UX of something we already ship.
"Ahead" means keep it and do not regress. Deep code notes live in the sibling docs; this file is the full map.

**Related.** [SUMMARY.md](SUMMARY.md) (ranked adopt list), [upload-and-retry.md](upload-and-retry.md),
[sync-and-restore.md](sync-and-restore.md), [gallery-and-grid.md](gallery-and-grid.md),
[viewer-and-video.md](viewer-and-video.md).

**Reading the Status columns.** "Ahead" and "Parity" come from reading code and the test plan, not from a device run.
Competitor claims such as Ente's concurrency or Immich's trash retention were skimmed in shallow clones and are not
verified. After this file was written, SUMMARY items 1 to 3, 8 and 9 were written (see the status table there).

**Caveats.** Competitor "weak spots" mix their docs, known issues, and agent reading of shallow clones. Lelvo
rows cite our code or `docs/MANUAL_TEST_PLAN.md` / `docs/PROGRESS.md`. Nothing here replaces a device check.
Columns: **Status** = Ahead / Parity / Gap / Partial / Not planned.

---

## Legend

| Status | Meaning |
|---|---|
| Ahead | Lelvo already stronger; protect it |
| Parity | Same job done; polish until we feel better |
| Gap | We ship it, but it is weaker or unproven vs them |
| Partial | Built on some platforms / paths only |
| Not planned | Refused on purpose (`docs/not-planned.md`) — listed so we do not "improve" into it |

---

## 1. Trust (fix first)

### 1.1 Backup engine — upload, verify, retry, resume

| | |
|---|---|
| **Ente** | Dart `FileUploader`, up to 4 concurrent, SQLite locks across foreground/background, ignored-files table, multipart resume, hard-fail classes (quota, invalid file), device-full stops the run |
| **Immich** | Foreground worker pool + OS `background_downloader` on background; SHA-1 dedupe; iCloud download progress; known issues: unreadable assets retry forever (#30458), re-queue storms after upgrade (#20331) |
| **Lelvo** | One engine, 2 lanes, exact `FLOOD_WAIT`, size-verified "done", Retry button only for failed, part resume, stall watchdog, kill-safe queue (`BackupEngine.swift` / `.kt`) |
| **Missing / weaker** | Halt on session revoked / channel gone / disk-full is now written (unverified on device); no ignore-list for permanently unreadable assets; delete-while-queued and long FLOOD soak still device-open (`MANUAL_TEST_PLAN` 1.20, T.1–T.12) |
| **Better-than-them bar** | Every failure has a plain reason + one correct next step; never false "done"; never stranded forever; permanent errors halt the run with a banner |
| **Status** | Ahead on verify + FLOOD_WAIT; **Gap** on halt/ignore paths — see SUMMARY Tier 1 |

### 1.2 Auto / background backup

| | |
|---|---|
| **Ente** | Background sync on mobile; still incomplete for many users (push / OEM); Backup mode on iOS keeps screen awake for large runs |
| **Immich** | Auto backup when opened + background worker; Android OEM battery kills common; iOS Background App Refresh |
| **Lelvo** | AutoBackup prefs, BGAppRefresh / BGProcessing / ContinuedProcessing, Shortcuts, Mac hourly + menu bar, Android WorkManager + tile + Fix for OEM kills (`BackgroundTasks.swift`, `BackupScheduler`) |
| **Missing / weaker** | Cannot use `URLSession` background or Apple's unencrypted photo upload extension (E2E + MTProto); must win with honesty + Shortcuts + overnight + open-to-run; daily "backlog drains without opening" still the product bar |
| **Better-than-them bar** | Honest blockers with Fix; resume after kill; stuck reminder; backlog drains over days without false silence |
| **Status** | **Gap** (architecture limit) — polish the paths we *can* use |

### 1.3 Free Up Space

| | |
|---|---|
| **Ente** | Settings → Free up device space; backed-up only; Android trash behaviour improving |
| **Immich** | Free Up Space removes local copies already on server and not in Immich trash |
| **Lelvo** | Re-verify Telegram sizes before delete; user confirm; never auto-delete (`FreeUpSpaceService`) |
| **Missing / weaker** | Telegram-deleted items can look like Failed/Retry (1.22); wrong-library Free Up still to prove (1.23) |
| **Better-than-them bar** | Never offer delete unless Telegram just confirmed every part; cancel = nothing gone; "Removed from Telegram" never looks like a retryable upload fail |
| **Status** | Ahead on verify design; **Gap** on edge UX |

### 1.4 Counts / Backup tab

| | |
|---|---|
| **Ente** | Backup status + per-file progress; can feel opaque multi-device |
| **Immich** | Status/count drift is a recurring complaint |
| **Lelvo** | One shared count function: on device / backed up / cloud-only / waiting / failed |
| **Missing / weaker** | Large-lib recount lag; Failed vs Removed vs Limited access easy to miss |
| **Better-than-them bar** | One glance truth; green only when verified; FLOOD / limited access / removed are first-class |
| **Status** | Ahead on model; **Parity/Gap** on presentation at scale |

### 1.5 Sign-in / session recovery

| | |
|---|---|
| **Ente** | Email + SRP + 2FA; recovery key critical |
| **Immich** | Server URL + user / OAuth |
| **Lelvo** | Telegram phone + code + 2FA; Keychain/Keystore session; SessionWatch |
| **Missing / weaker** | Run now stops on a revoked session with a clear message (written, unverified); still to prove on device that the sign-in screen follows and the queue is intact (T.4) |
| **Better-than-them bar** | Session ended → clear path; library + queue intact; no hang / empty Libraries |
| **Status** | **Gap** on mid-run halt + banner |

### 1.6 Restore / new device / relink

| | |
|---|---|
| **Ente** | Sign in → cloud library; depends on Ente (or self-host) |
| **Immich** | Sign in → your server must be up |
| **Lelvo** | Sign in Telegram → unlock → scan channel; `RestoreLinker` / `PhotoLinker`; index snapshot for fast restore |
| **Missing / weaker** | A full scan that ended early could mark backed-up photos missing and re-upload them (guard now written, SUMMARY item 3); whole-library reads on each backup run (relink, snapshot check); edited/deleted phone copies edge cases; large first-scan feel |
| **Better-than-them bar** | Unlock → scan → phone photos relinked; nothing re-uploaded that is already in the channel |
| **Status** | Ahead on "no server to bring up"; **Parity** on polish |

### 1.7 Encryption unlock / recovery key

| | |
|---|---|
| **Ente** | Audited E2E; recovery key; passphrase anxiety well documented |
| **Immich** | No library E2E (server can read files) |
| **Lelvo** | Always E2E for new libraries; Argon2id; recovery key; Passwords autofill on iOS |
| **Missing / weaker** | Public audit like Ente; confirm-again / change-passphrase lightly proven on device |
| **Better-than-them bar** | Wrong key refuses without wipe; recovery key groups clear; Passwords autofill works |
| **Status** | Ahead vs Immich; **Parity/Gap** vs Ente UX + proof |

---

## 2. Daily feel (Photos-like)

### 2.1 Gallery timeline / grid

| | |
|---|---|
| **Ente** | Flutter sectioned sliver; pinch zoom; swipe-select; year ticks on long lists; jump-to-date |
| **Immich** | Flutter bucketed timeline; scrubber with year labels + haptic; ThumbHash placeholders; known huge-lib scrubber bugs |
| **Lelvo** | Native `UICollectionView` / `NSCollectionView` / Compose grid; pinch day/month/year; swipe-select; date scrubber; thumbnail pipeline |
| **Missing / weaker** | Year ticks on scrubber; jump-to-date; ThumbHash (needs format bump); Android drag-select O(n); 50k device FPS unproven — details in [gallery-and-grid.md](gallery-and-grid.md) |
| **Better-than-them bar** | 60 fps at 40k+; scrubber keeps up like Photos; badges truthful; no sync freeze |
| **Status** | Ahead on Apple native path; **Gap** on scrubber polish + Android cost + device proof |

### 2.2 Viewer (photo / video / Live / Motion)

| | |
|---|---|
| **Ente** | Full-screen viewer; Live/Motion improving; cast |
| **Immich** | Asset viewer; Live/Motion; editor; OCR overlay; slideshow |
| **Lelvo** | Pager, zoom, Live/Motion chips, custom video controls, AirPlay (Apple), info panel |
| **Missing / weaker** | Retry on viewer error; Live when swiping onto item; player-fail → fast version (SUMMARY Tier 3); seamless quality switch |
| **Better-than-them bar** | Photos-like pager; Live every time; sound stops on close; resume mid-video; no black screen on failure |
| **Status** | **Parity/Gap** — see [viewer-and-video.md](viewer-and-video.md) |

### 2.3 Video streaming / fast versions

| | |
|---|---|
| **Ente** | Stream from encrypted cloud; buffers on cellular for originals |
| **Immich** | Server HLS / transcode (preview); network-dependent |
| **Lelvo** | Ranged TDLib + CGFE decrypt; `sp` fast copy; Automatic stall → fast |
| **Missing / weaker** | Quality switch restarts player; cloud-only "Make fast version" may download original first (`PROGRESS.md`) |
| **Better-than-them bar** | Seek that works; stall fallback; quality change without a dead screen |
| **Status** | Ahead on no-server streaming; **Gap** on seamless switch |

### 2.4 Albums / favorites sync

| | |
|---|---|
| **Ente** | Collections solid; E2E share (we skip share) |
| **Immich** | Albums + shared albums; device→server album sync |
| **Lelvo** | Albums + favorites via channel meta notes; still labeled **beta** |
| **Missing / weaker** | Drop beta only after multi-device soak; cloud-only ↔ Photos join rules confuse |
| **Better-than-them bar** | Same hearts/albums on every device; hearts also match Apple Photos / MediaStore where possible |
| **Status** | **Gap** (beta → solid) |

### 2.5 Multi-device meta sync (favorites, albums, lock, trash)

| | |
|---|---|
| **Ente** | Server-mediated sync of encrypted metadata |
| **Immich** | Server event stream |
| **Lelvo** | Channel notes (`MetaSync` / `NoteSync` / `TrashSync`); ~10–15 s pacing |
| **Missing / weaker** | Note storms / compaction; delay can feel like "didn't sync"; two-device backup soak open (T.11) |
| **Better-than-them bar** | Changes show up reliably; kill mid-sync still safe; never lose the only copy of a note |
| **Status** | Ahead on "channel is truth"; **Gap** on feel of latency + soak tests |

### 2.6 Recently Deleted

| | |
|---|---|
| **Ente** | Trash with recovery |
| **Immich** | Trash; 30-day style retention; past bugs deleting wrong assets |
| **Lelvo** | 30-day Recently Deleted + cross-device trash notes |
| **Missing / weaker** | Days-left clock skew across devices; Free Up vs trash interaction to keep boring |
| **Better-than-them bar** | Same days-left everywhere; recover on any device; Free Up never fights trash |
| **Status** | **Parity** |

### 2.7 Offline / cache

| | |
|---|---|
| **Ente** | Viewed cache; uneven without network |
| **Immich** | Offline support on mobile; thin without server |
| **Lelvo** | Thumb ~300 MB + viewed ~1 GB LRU; Clear in Settings; TDLib optimizeStorage on Apple |
| **Missing / weaker** | Offline-open of known cached items still unproven (4.20); "why is cache big?" not obvious enough |
| **Better-than-them bar** | Cached items open offline; caps + Clear have an obvious effect; no surprise re-downloads |
| **Status** | **Gap** (prove + explain) |

---

## 3. Migrate and round-trip

### 3.1 Google Takeout import

| | |
|---|---|
| **Ente** | Strong desktop import story |
| **Immich** | CLI / external takeout paths; often painful |
| **Lelvo** | Guided Takeout on **iOS + Mac** (`TakeoutImporter`); user-confirmed zip delete only |
| **Missing / weaker** | **Never run on a real Takeout device**; Android Takeout missing; multi-zip + sidecar-later (B.4–B.9) open |
| **Better-than-them bar** | Kill mid-zip → resume; zero re-uploads; every skip explained; multi-zip dates correct |
| **Status** | **Gap** (built, unproven); Partial (no Android) |

### 3.2 Save to Photos / phone

| | |
|---|---|
| **Ente** | Download / save; metadata mostly kept |
| **Immich** | Download; metadata often incomplete |
| **Lelvo** | Save Original with date/albums/favorites where possible |
| **Missing / weaker** | Video + Live cloud-only round-trip less complete than stills (1.19) |
| **Better-than-them bar** | Byte-exact original + date/place/albums/favorites |
| **Status** | **Partial/Gap** |

### 3.3 Download a copy / second copy

| | |
|---|---|
| **Ente** | Desktop incremental export |
| **Immich** | Download / disk on server |
| **Lelvo** | Resumable export; Mac/Android folder second copy (Pro-gated on some paths) |
| **Missing / weaker** | Android SAF folder path lightly proven; space-needed messaging |
| **Better-than-them bar** | Resumable; pause if drive gone; never delete the only copy |
| **Status** | **Parity/Partial** |

### 3.4 Duplicates

| | |
|---|---|
| **Ente** | Similar / storage tools; delete UX can scare |
| **Immich** | Duplicate detection uneven by version |
| **Lelvo** | Exact Telegram/phone dupes free; similar groups; Smart Cleanup is Pro |
| **Missing / weaker** | Naming (Duplicates vs Smart Cleanup) confuses; large-lib similar timing unproven |
| **Better-than-them bar** | Exact free + clear "Select extras"; trash, not silent wipe |
| **Status** | **Parity** |

---

## 4. Lower urgency (still shipped — polish only)

### 4.1 Search (place / date / name / things)

| | |
|---|---|
| **Ente** | On-device faces + magic search (we are **not** adding faces) |
| **Immich** | Server CLIP / faces / metadata |
| **Lelvo** | Free: place/date/name; Pro: things (Vision/ML Kit on **local** photos); OCR on Apple |
| **Missing / weaker** | Index backlog / iCloud-optimized "no image yet" silent holes; Android place parity |
| **Better-than-them bar** (within scope) | Results appear as index fills; no silent holes; suggestions stay useful |
| **Status** | **Gap** on index honesty; Not planned: faces / server CLIP |

### 4.2 Map

| | |
|---|---|
| **Ente** | Map of geotagged items |
| **Immich** | Global map |
| **Lelvo** | Map + clusters (Apple Maps / MapLibre) |
| **Missing / weaker** | Large-library pin load / cluster feel |
| **Better-than-them bar** | Smooth clusters; tap → grid |
| **Status** | **Parity** |

### 4.3 Memories

| | |
|---|---|
| **Ente** | On-this-day stories; share (we skip share) |
| **Immich** | Memories (x years ago) |
| **Lelvo** | On-this-day / recent / trips + story player; Pro themes |
| **Missing / weaker** | Trip quality & covers below Google bar; player edge cases |
| **Better-than-them bar** | Story never dead-ends; trips look intentional |
| **Status** | **Parity/Gap** |

### 4.4 Onboarding

| | |
|---|---|
| **Ente** | Account wall |
| **Immich** | Server URL wall |
| **Lelvo** | Intro → Telegram → library → photos → first backup; auto-backup offered |
| **Missing / weaker** | Welcome-back scan feel; passphrase AutoFill under test tooling |
| **Better-than-them bar** | First photo feels safe; returning user feels instant |
| **Status** | **Parity** |

### 4.5 Settings / storage / cache

| | |
|---|---|
| **Ente** | Storage / free-up entry points |
| **Immich** | User + admin-ish settings |
| **Lelvo** | Backup options, storage caps, Telegram inactivity, logs, About |
| **Missing / weaker** | Cache size explanation; TDLib optimize outcomes not user-visible enough |
| **Better-than-them bar** | "Why is this big?" + Clear has an obvious effect |
| **Status** | **Gap** (clarity) |

### 4.6 iOS · Android · Mac parity

| | |
|---|---|
| **Ente** | Flutter "same" with platform gaps; Windows/Linux/web |
| **Immich** | Mobile Flutter + web; no official native Mac |
| **Lelvo** | One product on three; Mac native; Android near parity, Phase N gate open |
| **Missing / weaker** | Android writes to real library gated; Takeout Apple-only; Play Billing later; viewer/grid parity items |
| **Better-than-them bar** | Bug found on one OS fixed on all three in the same change |
| **Status** | Ahead on Mac vs Immich; **Gap** until Phase N + shared polish |

---

## 5. Explicitly not improving into (not planned)

Do not treat these as "missing features to catch up."

| Topic | Ente / Immich | Lelvo |
|---|---|---|
| Face recognition / people albums | Both have | Not planned |
| Public / partner album links | Both have | Not planned — system share sheet only |
| Lelvo server / accounts / analytics | Immich self-host; Ente cloud | Not planned |
| Backup to Drive / Dropbox / S3 | Various | Not planned — Download a copy instead |
| Windows / Linux / web | Ente yes; Immich web | Not planned |
| Ignore FLOOD_WAIT / raise parallelism | N/A | Not planned |
| Auto-delete from device without confirm | Neither should | Not planned |

---

## 6. Suggested work order

1. **Trust** — SUMMARY Tier 1 (halt on auth/disk, ignore list, vanished confirm) + Free Up 1.22/1.23 + session mid-run.
2. **Background honesty** — blockers, Fix, stuck reminder, prove backlog drains.
3. **Gallery / viewer polish** — SUMMARY Tier 2–3 + 40k device proof.
4. **Albums/favorites out of beta** — multi-device soak, then drop the label.
5. **Takeout** — one real multi-zip device run (B.4–B.9); then Android if needed.
6. **Lower urgency** — search holes, map, memories, settings copy, parity.

---

## 7. Checklist (tick when the bar is met on device)

### Trust (each box is proven by the matching `MANUAL_TEST_PLAN.md` rows, not by this list alone)
- [ ] Backup failures: plain reason + one next step; no false done; no stranded forever
- [ ] Auto backup: honest blockers + Fix; resume after kill; backlog drains
- [ ] Free Up: verify-only delete; Telegram-gone ≠ Retry
- [ ] Counts: green only when verified; waiting/failed/removed/limited/FLOOD clear
- [ ] Session recovery: clear re-sign-in; queue intact
- [ ] Restore: unlock → scan → relink; no needless re-upload
- [ ] Encryption unlock: recovery key + wrong key safe

### Daily feel
- [ ] Grid: 60 fps at large library; scrubber; truthful badges
- [ ] Viewer: Live every time; sound-off on close; resume mid-video; retry on error
- [ ] Video: stall fallback; no black screen on player fail
- [ ] Albums/favorites: no "beta"; same on every device
- [ ] Meta sync: reliable after kill
- [ ] Recently Deleted: same days-left; recover anywhere
- [ ] Offline/cache: cached open offline; Clear obvious

### Migrate
- [ ] Takeout: real multi-zip on device; kill-resume; every skip explained
- [ ] Save to Photos: bytes + metadata for photo/video/Live
- [ ] Download a copy / second copy: resumable; pause if drive gone
- [ ] Duplicates: clear Select extras; trash only

### Lower urgency
- [ ] Search: no silent iCloud holes
- [ ] Map: smooth at scale
- [ ] Memories: never dead-ends
- [ ] Onboarding: first photo safe; welcome back instant
- [ ] Settings: cache explained
- [ ] Parity: one fix ships on iOS + Android + Mac
