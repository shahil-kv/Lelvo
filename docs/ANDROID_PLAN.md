# Android plan

The plan, the feature list and the progress note for the Android app, in one file. Tick boxes as steps land.
Decisions here are made; change them only on purpose, with the reason written down.

## Decisions

- **Same repository, `android/` folder.** The contract ([CLOUD_FORMAT.md](CLOUD_FORMAT.md)) and the test vectors
  ([test-vectors/](test-vectors/)) stay single copies; Android tests read them in place. No code is shared with Swift.
- **Native Kotlin, every iPhone feature.** Jetpack Compose and Material 3 with Lelvo's own colours (not the
  wallpaper's), the same four tabs, the same features and words. Android's own controls where it has them.
- **End-to-end encrypted only.** Android creates only encrypted libraries and opens only encrypted libraries (header
  formats 1 and 2). A library without encryption gets a plain message: open it in Lelvo on iPhone or Mac. Android
  never writes a plain resource.
- **Never write what we can't read.** A newer header or unknown format version is "incompatible", never "missing":
  Android stops and says so. Android doesn't upgrade a format 1 header in the beta; the iPhone app does that.
- **Same TDLib.** TDLib 1.8.68, commit `18c8f7a0` (the one TDLibKit pins in `project.yml`), built for Android with
  the official `example/android` scripts. Its Java/JNI binding, no third-party Telegram client.
- **Original bytes.** Backups upload the file exactly as MediaStore stores it, with `ACCESS_MEDIA_LOCATION` and
  `MediaStore.setRequireOriginal()` so Android doesn't strip the location. A Motion Photo is one JPEG with the video
  inside; it is uploaded as is (kind `p`).
- **Captions carry no Android-only fields.** Anything new in a caption is a format change (AGENTS.md rule 2).
- **Writes never touch the real library before the gate.** The owner's real account may be used to read their
  library; backups, deletes and notes go to an "Android test" library until Phase N passes (owner, 2026-11-11).

### Modules

```
android/
  core/       pure Kotlin/JVM: caption codec, part layout, header, CGFE, key derivation, indexer, job machine
  telegram/   Android library: TDLib (JNI + TdApi), sign-in, channel, confirmed uploads, ranged reads, FLOOD_WAIT
  data/       Room index, MediaStore, Keystore, repositories
  app/        Compose UI, Media3 player, WorkManager and the upload service
```

### Libraries (one umbrella issue labelled `approved` before Step 1)

| Need | Library |
|---|---|
| UI | Jetpack Compose, Material 3, Navigation, Lifecycle |
| Grid paging | Paging 3 |
| Images | Coil 3 (custom fetcher: Telegram thumbnail → CGFE decrypt) |
| Zoom | Telephoto (saket/telephoto) |
| Video | Media3 ExoPlayer and UI (custom `DataSource`: byte range → TDLib → CGFE decrypt), Media3 Transformer for the fast version |
| Index | Room (KSP) |
| Background | WorkManager |
| Argon2id | argon2kt (native; Bouncy Castle's Java version can run out of memory at 256 MiB) |
| JSON | kotlinx.serialization |
| Tests | JUnit 5, Turbine |

AES-GCM, HMAC, PBKDF2 and SHA-256 come from `javax.crypto`; HKDF is ~20 lines on top of HMAC.

## Models

| Work | Model |
|---|---|
| Format and crypto, library unlock and new library (B), the indexer (C), video `DataSource` (D), the backup engine (I), the gate (N), stubborn bugs | Fable |
| Everything else: Gradle, screens, Room, WorkManager, wiring | Opus |
| Wide searches (Explore agent) | Haiku |

## The goal: everything the iPhone app does

Android gets every feature of the iPhone app, one at a time, until nothing is missing. Only the controls change
where Android has its own (Material player controls, the system photo picker, share sheet, the delete prompt), and a
few iPhone-only things get their Android version (Shortcuts → app shortcuts and a Quick Settings tile, AirPlay →
nothing for now). The table at the end of each phase names the iOS files to read first.

### How every feature is built

1. **Read the iOS code** named in the row, and its fixes: `git log --oneline -- <files>`, then the pull requests
   behind each fix. Write the edge cases under the phase's notes.
2. **Read one or two Android apps** that already do it (`.claude/rules/android.md` has the list). Note the device
   quirks and fixes they found.
3. **Write it**: logic in `core/` with JVM tests, services in `telegram/` and `data/`, screens in `app/`.
4. **Compare again** with the iOS code side by side: errors, retries, app killed mid-way, no network, permissions
   revoked, empty states, large libraries. Fix or write down each gap.
5. **Prove it** on the emulator (demo library) and, for anything that touches Telegram, on the real account (below).
   A feature is ticked only after that.

### Testing with the owner's real Telegram account

The owner signs in on Android with their real account (code and two-step password) once Phase B's sign-in is ready.
That unblocks everything that reads from Telegram. To keep their real library safe:

- **Reading is fine** from the real library: unlock, scan, timeline, viewer, video, save to phone.
- **Writing goes to a test library only** until the cross-platform gate (Phase N) passes: a second library on the
  same account, made with "New library" on the iPhone, named "Android test". Backup, delete, favorites, albums,
  Recently Deleted and re-scan run there, never on the real library. The Android app shows which library is open on
  every write screen in debug builds.
- Debug builds still default to the test servers; `telegram.testDc=false` in `local.properties` switches to the real
  servers for this testing.

### Look

- Lelvo's colours, not the wallpaper's: dynamic colour off, the accent from `design/tokens.json` (`#4E01F1` light,
  `#9B7BFF` dark), status colours with the same meaning as iOS (green backed up, orange attention or paused, red
  deletes or fails, grey not started). `Scripts/design-tokens.py` also writes the Android colours, so they never drift.
- **Feels like Google Photos** (owner, 2026-11-11): the iPhone's features and words, shown the way Google Photos and
  Android show them. Each screen starts by looking at Google Photos' version; iOS-only patterns get the Android one
  (table in `.claude/rules/android.md`). Every step is checked in light and dark.
- The same tabs as the iPhone: **Photos, Collections, Search, Backup**, with Settings behind the gear.
- The same badges and icons meanings (green cloud = in your library, phone = only on this phone, and so on), the same
  words, the brand mark on the launch screen (Android splash screen API) and in onboarding.

## Phase 0. Prove the core works like the iPhone (before A–N)

Nothing is built on the base until it is proven on the owner's real library, side by side with the iPhone app. Debug
builds have a **Core check** (timeline menu) that runs these against the open library; it only reads.

| Check | Proves | Compare with | Status |
|---|---|---|---|
| Real sign-in: phone, code, two-step password; force-stop, reopen, still signed in | Sign-in and the TDLib session | — | ✅ 2026-11-11 |
| Find the library, read the header, unlock with the passphrase (and with the recovery key) | Header formats 1–2, Argon2id, key check, Keystore | The iPhone opens the same library | ✅ passphrase, format 2; recovery key not tried |
| Full scan: messages, items, incomplete, duplicates, notes | Caption decoding, the indexer, history paging | The iPhone log line "Library scan (full): …" for the same library | ✅ equal: 2918 messages, 1124 items, 1 incomplete, 0 duplicates; notes 12 + 8 |
| Thumbnails: 5 decrypted, hash equal to the caption, decodable | CGFE, the `t` role, downloads | — | ✅ |
| Ranged read of a video, decrypted | `CgfeRandomReader`, split parts, `readFilePart` | The same bytes of the whole file | ✅ one-part video; a split video still to try |
| Originals: 3 photos and 1 video downloaded whole, size and SHA-256 equal to the caption | Bit-for-bit originals, split parts | The caption `h` the iPhone wrote | ✅ |
| Item count after notes (Recently Deleted, favorites, albums) | Notes applied | The iPhone's photo count | ✅ 2026-11-11: 1,075 shown, 49 in Recently Deleted, 49 favorites, the same as the iPhone (owner) |

A failure here stops the work until it's fixed; nothing in A–N starts on a base that doesn't match.

## Phases

Each row is one feature; a phase is a few pull requests. Status: ✅ done, ◐ part done, blank not started.

### Phase A. Foundation (architecture)

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Modules: core / telegram / data / app | `Packages/LelvoCore`, `Shared/Services` | Gradle modules | ✅ |
| Format and crypto (captions, header, CGFE, keys) | `LelvoCore/Format`, `Crypto` | `core/`, 66 tests on the shared vectors | ✅ |
| TDLib built for Android | `TDLibKit` in `project.yml` | `android/Scripts/build-tdlib.sh` | ✅ |
| Services container | `Shared/App/AppEnvironment.swift`, `AppModel.swift` | `LelvoApp` holds services and `resetEverything`; `AppModel` holds the tab, the session id and reset | ◐ (reset not yet run on a device) |
| Theme and colours | `design/tokens.json`, `docs/DESIGN.md` | Lelvo colour scheme, no dynamic colour; tokens script writes `LelvoColors.kt` | ✅ |
| App shell: 4 tabs, Settings, navigation | `iOS/Views/RootView.swift`, `SettingsButton.swift` | Bottom navigation bar, gear on every tab, demo banner on every tab, Back returns to Photos | ✅ (Collections, Search, Backup are placeholders until G, H, I) |
| Preferences | `Shared/Services/Preferences.swift` | `Prefs`: same keys and defaults; iPhone-only keys left out with the reason; grid columns kept | ✅ |
| Logs with redaction | `AppLog.swift`, `LelvoCore/Support/Redactor.swift` | `AppLog` and `Redactor` in `core/` (so `telegram/` logs through it too), with tests | ✅ |
| Toasts | `Shared/Views/Toast.swift` | `Messages` + one snackbar host over every screen | ✅ |
| Launch screen and brand mark | `Shared/Views/Brand/` | Splash screen API, vector mark, iOS opening, adaptive icon | ✅ (tap to skip not proven) |
| Review demo | `Shared/App/DemoMode.swift` | `DemoMode` | ✅ |

### Phase B. Onboarding and sign-in

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Intro pages | `Shared/Views/Onboarding/IntroView.swift` | Horizontal pager, same pages and words | ✅ (permission prompt still to run) |
| Phone, code, two-step password, other device, no account | `OnboardingView.swift`, `TDService.swift` | `SignInScreen` | ◐ (needs one real sign-in) |
| Where the code was sent | `CodeSentCard.swift` | Card on the code step | ✅ |
| Session ended elsewhere | `LelvoCore/Support/SessionWatch.swift` | `SessionWatch` port | ✅ (no screen on iOS either: the reset shows the intro; device run waits with A7) |
| Choose library, unlock, recovery key | `LibraryService.swift`, `EncryptionSettingsView.swift` | `LibraryScreens`, `RecoveryKeyScreen` | ◐ (needs real run) |
| New library with recovery key shown and confirmed | `OnboardingView.swift` (`.recoveryKey`), `PassphraseBox.swift` | Header format 2 writer, key screens | ◐ (needs a real create on "Android test") |
| Scanning and "library ready" | `LibraryReadyView.swift` | Progress screen, item count | ◐ (scan screen done; "library ready" waits for the first upload, Phase I) |
| Photo permission (full, partial, location) | `OnboardingView.swift` (`.photos`), `PhotoLibraryService.swift` | `READ_MEDIA_*`, partial access (Android 14), `ACCESS_MEDIA_LOCATION` | ◐ (photos step done; prompt and partial not run) |

### Phase C. Library and index

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Room index | `LelvoCore/Index/LibraryStore.swift` | `items` table | ✅ (7a) |
| Channel scan into the index, snapshots | `LibraryIndexer.swift`, `IndexSnapshot.swift`, `LibraryService.swift` | `core/` indexer, `data/` scanner | ✅ full, recent and from the snapshot, real library (writing snapshots: Phase I) |
| Follow new messages | `LibraryService.swift` (updates) | TDLib update flow | ◐ (built; needs a backup or delete on the iPhone while Android is open) |
| Favorites, albums, Recently Deleted notes | `MetaLog.swift`, `TrashLog.swift`, `CloudTrash.swift` | Apply notes in the index | ✅ read and applied (sending them: Phase L) |
| Link cloud items to phone photos | `RestoreLinker.swift`, `Deduplicator.swift` | MediaStore id from `l`, else name + second + size (as iOS; no hashing) | ◐ (built; the emulator has none of the owner's photos) |
| Re-scan, rename, switch, new library | `LibraryService.swift`, `SettingsView.swift` | Settings rows | ◐ (re-scan run; switch needs a second library, new library writes) |

### Phase D. Reading media from Telegram

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Ranged, confirmed downloads | `MediaReader.swift`, `TDService.swift` | `TdClient` download + range reads | ✅ `MediaReader`: parts, CGFE chunks, an expired file reference looked up again through its message |
| Thumbnail, screen copy, original | `CloudMediaService.swift`, `ScreenCopy.swift` | `data/` media service | ✅ `CloudMedia`: thumbnail → screen copy → original (or edit) layered in the viewer, neighbours ahead on Wi-Fi |
| Thumbnail cache | `ThumbnailPipeline.swift`, `LelvoCore/Cache/LRUDiskCache.swift` | Coil fetcher (TDLib → CGFE decrypt) + disk cache | ✅ 8 at a time, 300 MB thumbnails, 1 GB viewed originals (`DiskCache` in `core/`) |
| Video streaming, quality, fast version | `StreamingAsset.swift`, `CloudVideo.swift`, `VideoQuality.swift`, `MovieLayout.swift` | Media3 `DataSource` over decrypted ranges | ◐ streams with one block read ahead, fast version by the setting; the in-viewer quality switch and the stall fallback come with Phase F |
| Resume where you left off | `Shared/Support/PlaybackPositions.swift` | Same rule, prefs | ◐ built and unit-tested; no video over 2 minutes tried yet |

### Phase E. Photos tab

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Grid with day / month / year, pinch | `NativePhotoGrid.swift`, `GalleryModel.swift`, `GridSnapshot.swift` | `TimelineScreen` | ✅ real thumbnails, phone and cloud |
| Phone photos and cloud items in one timeline | `GalleryModel.merge`, `PhotoLibraryService.swift` | MediaStore scan + index | ✅ `Gallery.merge` in `core/` (tested); MediaStore changes redraw at most every 1.5 s |
| Status badges and "what the icons mean" | `NativePhotoGrid.swift`, `GalleryView.swift` | Cell badges, help sheet | ✅ the iPhone's badges, colours and words; heart, length, Live mark; legend sheet |
| Date scrubber | `NativePhotoGrid.swift`, `VideoNavigation.swift` | Fast-scroll thumb with date | ✅ |
| Filters: videos, Live Photos, favorites, only in Telegram, not backed up | `GalleryModel.swift` (`Filter`) | Filter chips in the top bar menu | ✅ menu + chip to clear |
| Select, swipe to select, select all | `SwipeSelection.swift`, `GalleryView.swift` | Long-press + drag selection | ✅ with edge auto-scroll |
| Actions: back up, share, favorite, add to album, delete (phone / Telegram / everywhere) | `GalleryActions.swift`, `GalleryView.swift` | Bottom action bar, dialogs, system delete prompt | ◐ share (cloud too), favorite and trash on the phone; back up (Phase I), albums (G), favorites and deletes in Telegram (L) |

### Phase F. Viewer

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Swipe between items | `ViewerView.swift` | Pager | ✅ swipe down closes, swipe up opens details (Google Photos) |
| Zoom, double tap | `ViewerView.swift` | Telephoto | ✅ tiles from the file once zoomed, so big photos stay sharp |
| Screen copy first, then original | `CloudMediaService.swift` | Two-step load | ✅ |
| Info: date, place, camera, size, where it is | `ViewerView.swift` (Info), `ExtraMetadata.swift` | Bottom sheet | ✅ camera and place from EXIF; place opens the maps app |
| Share original, save to phone, favorite, delete | `ViewerView.swift`, `GalleryActions.swift` | Top bar and bottom bar | ◐ share (and original), save, favorite and delete on the phone; Telegram-side favorite and delete wait for L, back up for I |
| Live Photos (press to play), Motion Photos | `ViewerView.swift` | Media3 with the paired video | ✅ cloud Live Photos (LIVE chip or long press); the phone's own Motion Photos (MOTION chip) |
| Video player: speed, quality, sound off on close | `CloudVideo.swift` | Own controls over Media3 | ✅ play, scrubber with frame strip, times, mute, speed, double tap ±10 s, quality pill, stall fallback |

### Phase G. Collections tab

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Albums from the phone and from your library | `AlbumsView.swift`, `AddToAlbumView.swift`, `MetaSync.swift` | MediaStore buckets + Lelvo albums | ✅ read: Lelvo albums, phone folders, See all |
| Add to album, rename, delete album | `AddToAlbumView.swift`, `AlbumsView.swift` | Dialogs | |
| Favorites, videos and other smart rows | `AlbumsView.swift` | Same rows | ✅ Recent days, Favorites, media types |
| Recently Deleted (30 days, restore, delete now) | `RecentlyDeletedView.swift`, `TrashGrid.swift`, `TrashSync.swift` | Grid + actions | ◐ grid with days left; Recover and Delete send notes (Phase L) |
| Memories | `MemoriesView.swift`, `LelvoCore/Support/Memories.swift`, `MemoriesSettingsView.swift` | Cards, same rules | ◐ on this day, recent, trips, story player, settings; no themes or place names yet |
| Map | `PhotoMapView.swift` | Needs a map library issue | blocked: needs a map library on the approved list |

### Phase H. Search tab

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Search by date, place, file name, album | `SearchService.swift`, `SearchMatcher.swift`, `SearchModel.swift` | `core/` matcher port | |
| Suggestions | `SearchSuggestions.swift` | Suggestion chips | |
| Things in photos (labels) | `SearchService.swift` (Vision) | On-device labels; needs its own issue | |

### Phase I. Backup tab and backup engine

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Job queue, slots, order, stalls, speed | `BackupEngine.swift`, `LelvoCore/Backup/*` | `core/` ports with tests, `data/` engine | |
| Confirmed encrypted uploads, split parts | `CloudUploader.swift`, `FileCrypto.swift` | `TdClient` uploads | |
| Thumbnail and screen copy at backup | `ScreenCopy.swift`, `CloudUploader.swift` | Same sizes and roles | |
| Fast version of videos | `StreamingCopyEncoder.swift` | Media3 Transformer | |
| Edits and extras | `EditCheck.swift`, `ExtraMetadata.swift` | Android has no edit recipe: original only; noted gap | |
| Dashboard: counts, progress, pause, retry failed | `BackupDashboardView.swift`, `BackupCounts.swift`, `TransferRate.swift` | Backup tab | |
| Extra copies in Telegram, removed from backup | `Deduplicator.swift`, `RemovedFromBackupView.swift` | Rows on the Backup tab | |
| Free up space | `FreeUpSpaceService.swift`, `FreeUpSpaceView.swift` | Verify in Telegram, then `createDeleteRequest` | |
| Save everything to the phone | `SaveAllToPhotosView.swift`, `RestorePlan.swift` | MediaStore writes with date and place | |
| Second copy to a folder | `SecondCopyService.swift`, `SecondCopy.swift` | Storage Access Framework folder | |

### Phase J. Background and automation

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Back up new photos automatically | `BackgroundTasks.swift`, `PhotoChangeScan.swift` | WorkManager with a MediaStore content trigger | |
| Long runs with progress | `BackgroundTasks.swift` (continued task) | User-initiated job or `dataSync` foreground service | |
| Wi-Fi only, while charging | `Preferences.swift`, `SettingsView.swift` | WorkManager constraints | |
| Shortcuts: back up, status, free up space | `iOS/Intents/BackupIntents.swift`, `AutomationGuideView.swift` | App shortcuts and a Quick Settings tile | |

### Phase K. Settings

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Signed in as, library, encryption, storage, version | `SettingsView.swift` | Grouped settings screen | |
| Change passphrase, recovery key | `EncryptionSettingsView.swift`, `PassphraseBox.swift` | Header rewrite (same format) | |
| Backup options | `SettingsView.swift` | Same toggles | |
| Telegram account kept for 2 years | `SettingsView.swift`, `TDService.swift` | Same row | |
| Logs: share, clear | `SettingsView.swift`, `AppLog.swift` | Share sheet | |
| Report a problem, suggest a feature | `FeedbackView.swift`, `LelvoCore/Support/Feedback.swift` | Email / GitHub intents | |
| About, licences, privacy, questions and answers, source code | `SettingsView.swift`, `AppLinks.swift` | Same rows | |
| Sign out and reset | `AppEnvironment.swift` (`reset`) | Same wording | ◐ (in Settings; reset of every store comes with K) |

### Phase L. Sync between devices

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Favorites and albums notes, 10 s pacing | `MetaSync.swift`, `MetaLog.swift` | Same notes, outbox table | |
| Recently Deleted notes | `TrashSync.swift`, `TrashLog.swift` | Same notes | |
| Favorite on the phone | `PhotosFavoriteSync.swift`, `PhotosFavorite.swift` | MediaStore `IS_FAVORITE` (Android 11+) | |

### Phase M. Similar photos and duplicates

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Duplicates and similar photos | `SimilarPhotosService.swift`, `SimilarPhotos.swift` | On-device; needs its own issue for the model | |

### Phase N. Cross-platform gate, parity audit and release

- [ ] **Parity audit.** Walk every iOS file in `Shared/`, `iOS/` and `Packages/LelvoCore` and every row of this plan;
      for each iOS feature, setting, message and edge case, point to the Android code that does it, or write down why
      Android differs. Nothing is lost or missing without a written reason. The list goes in the pull request.

- [ ] iPhone backs up → Android shows, plays and saves it, bytes equal; and the other way round, iPhone and Mac.
- [ ] Large split videos, Live Photos, Motion Photos, interrupted uploads, the same photo on both phones (one copy).
- [ ] Android 10, 13, 14, 15, 16 on real phones or emulators.
- [ ] Only then: Android may write to the real library.
- [ ] Release signing, Play Console internal testing, privacy policy covers Android.

### Order

Phase 0 (core check on the real library) → A (theme, shell, prefs, logs) → B → C → D → E → F → I (on the test library) → J → K → G
→ L → H → M → N. Screens that don't need Telegram are built on the demo library first, then switched to real data.

## Progress

- Step 1 done 2026-11-11: Gradle 9.8.2, AGP 9.4.1, Kotlin 2.4.21, Compose BOM 2026.09.00. Empty app runs on
  the Pixel 9 emulator (Android 16); `:core:test` reads the vectors in place.
- Step 4 done 2026-11-11: TDLib built with NDK 27, 16 KB page aligned (checked `LOAD … 0x4000`), runs on the emulator.
- Step 5 in progress: phone → code → password screens, TDLib session survives relaunch, Telegram errors show the iOS
  wording. Not yet proven: a completed sign-in. Test-server numbers (`+99966 X YYYY`) reach the code step but
  Telegram answers `PHONE_CODE_INVALID` to `XXXXX` and `XXXXXX` (tried DC 1–3, typed slowly). Next: sign in once
  with a real spare account (`telegram.testDc=false`), or find the current test-code rule.
  - iOS edge cases carried over: same auth steps and error sentences, code delivery and resend labels, codes of any
    length, session ended elsewhere (`SessionWatch`, with its tests), wait for the old client to close, a key read
    that fails is never treated as missing (iOS lost sessions that way), lost database key → fresh start, no message
    database, country table and number lengths.
  - Android additions: country from the SIM, SMS code autofill hint, pasted `+` numbers with unlisted codes.
- Steps 2–3 done 2026-11-11 (Fable, stopped early to save usage, then checked on Opus): every key of all four
  vector files is tested (54 tests). Not yet ported, needed later: LibraryIndexer (Step 7), RestorePlan (14),
  VideoQuality and MovieLayout (10), ScreenCopy (9), ExtraMetadata, PhotosFavorite, LibraryNames.
- Step 6 written 2026-11-11, not yet run end to end: `LibraryService` (find channels, header from the pinned message
  then the description, Newer/Damaged/Missing never "repaired", plain libraries refused, keys tied to their channel,
  recovery key tried before Argon2id, argon2kt off-heap), confirmed sends in `TdClient` (iOS `finishedSends`),
  choose and unlock screens. Creating a library on Android is Step 15.
- Demo mode, Step 7a and first screens done 2026-11-11 (on the Pixel 9 emulator): the review number and code open
  the sample library, "Back up now" simulates the 6 waiting items two at a time, sign out leaves demo mode and clears
  the index, and the demo survives a force-stop. Room index (`items` table, schema in `data/schemas/`), timeline grid
  with Today/Yesterday/day sections, pinch levels 2/3 columns (days), 5 (months), 8 (years), a swipe viewer, and the
  demo clips play in Media3. Core: `LibraryItem`, `Timeline`, `DemoLibrary` (12 new tests, 66 in all).
  - Decisions: the demo files are packaged straight from `iOS/DemoLibrary` (Gradle assets folder), not copied, so both
    apps always ship the same demo; the demo also works in a build without Telegram app keys, like iOS. The demo
    prompts say "review notes" rather than "App Review notes", since Play reviews it too. Room DAO behaviour is
    checked on the emulator, not in JVM tests (Robolectric isn't on the library list).
  - iOS edge cases carried over: an unknown status never reads as backed up; hidden and trashed items never show;
    undated items go last under "Unknown date"; a demo backup stopped mid-way resumes after the last finished item;
    the player is released when the page or viewer closes (iOS #115); the demo is never mistaken for a real library
    (banner always shown).
  - Bug found and fixed on the way: new items inserted above the newest section arrived off screen (lazy grids keep
    their place by key); the grid now stays pinned to the top when the user was at the top.
  - Known gaps: pinch not tried on a device yet (adb can't send two fingers); no fast-scroll with date, no zoom or
    info sheet in the viewer, no Live Photo playback; thumbnails for real items need the Coil fetcher (Telegram
    thumbnail → CGFE decrypt); no backup screen (the menu item is demo-only until Step 12).
- 2026-11-11: the step list became the full feature plan above (owner: everything the iPhone app does, Lelvo's
  colours, real account for reading, writes to an "Android test" library until the gate). Old step numbers in these
  notes map to phases: 1–4 → A, 5–6 → B, 7 → C, 8 → E, 9 → F, 10 → D, 11–14 → E and I, 15 → B and K, 16–17 → N.
- 2026-11-11: Phase 0 added (owner: prove the base works like the iPhone first, and audit for anything missing at
  the end). Written: indexer port (14 tests), `TdFiles` (paging documents, whole and ranged downloads, one download
  per file, FLOOD_WAIT), `LibraryScanner` (full scan), `CoreCheck` and its debug screen. Waiting for the owner's
  real sign-in to run it.
- Phase 0 run 2026-11-11 on the owner's real library (emulator, real servers): every check passed and the scan
  matches the iPhone's own log exactly (2918 messages, 1124 items, 1 incomplete, 0 duplicates, 12 favorites/albums
  notes, 8 Recently Deleted notes). Signed in once; force-stop keeps the session, the keys and the index.
  - **iOS bug found (told the owner, not copied):** the channel holds 16 index snapshots, though §7.1 says writers keep
    one. `writeSnapshotIfDue` remembers the previous snapshot only in the local index (`indexSnapshotMessageId`), so
    after a reinstall, sign-out or on a second device the older ones are never deleted.
  - Still to try: a split video (over 2,000 MiB), unlocking with the recovery key.
  - Testing rule: never clear the app's data or uninstall it on the emulator; the owner shouldn't have to sign in
    again (repeated logins risk Telegram limits). `adb install -r` keeps the session.
- 2026-11-11, Phase A so far: A1 colours ✅ (tokens → `LelvoColors.kt`, dynamic colour off), A2 tabs and Settings ✅
  (bottom bar, gear on every tab, Settings as an Android list), A3 Prefs ✅. Owner: the Android app must **feel like
  Google Photos**, not the iPhone (rule and pattern table in `.claude/rules/android.md`), and every step is checked in
  light and dark. The emulator stays signed in to the owner's real account: never clear its data (memory note).
- 2026-11-11, A4 logs ✅: `Redactor` (same five rules and order as iOS, 8 tests) and `AppLog` in `core/` rather than
  `data/`, because `telegram/` can't depend on `data/`. Same file rules as iOS: one file, 1 MB then rotated to
  `lelvo.old.log`, every line redacted on write and again on read, `api_hash` as a known secret. Logs live in
  `no_backup/logs` (never in Android backup); debug builds echo to logcat (tag `Lelvo`), release builds don't, like
  iOS's Debug-only print. Exceptions log their kind and message, never a stack trace. Every `android.util.Log` call
  now goes through it. Share and clear come with Settings (Phase K).
- 2026-11-11, A5 messages ✅: `Messages` is the iOS `ToastCenter` (progress with Stop, results 3.5 s, a late
  progress update never brings a message back, Stop cancels the work) shown as a Material snackbar, the way Google
  Photos does: no icons, an action button (Undo, View) where one helps, which keeps it up 6 s; results swipe away,
  progress doesn't; TalkBack reads it (live region). One host sits over the tabs, the viewer, Settings and the core
  check, lifted above the tab bar only while the tabs show. Debug-only hook to check it: `adb shell am start -f
  0x20000000 -n app.lelvo.android/.MainActivity --es lelvo.message "Title" [--es lelvo.style progress] [--ez lelvo.undo
  true]`. Checked on the emulator in light and dark: progress with Stop, Undo, Stop, swipe away.
- 2026-11-11, A7 services ◐: `AppModel` (iOS `AppModel`) holds the selected tab (so shortcuts can open one later),
  a session id that rebuilds every signed-in screen after a reset, and `reset()`: sign-in shows at once and the wipe
  runs behind it (iOS #70), resets run one after another, and only the last one clears the flag. `resetEverything`
  (iOS `AppEnvironment`) leaves the demo, signs Telegram out only when a session or sign-in is under way, then clears
  the index, the library's keys, the cached images and every setting. Sign out in Settings and in the demo both use
  it. **New on Android:** a session ended in Telegram → Devices now resets like iOS (before, Android only logged it
  and kept the index and keys). Known gaps: iOS keeps the Recently Deleted and favorites choices for that case
  (`LibrarySnapshots`); Android has none to keep until Phases C and L. Not yet run on a device: the emulator holds the
  owner's real session, so sign-out waits for a moment the owner chooses. Tabs and Back checked on the emulator.
- 2026-11-11, A6 preview approved (owner): **Option B, same as iPhone**: Android 12+ system splash with the white mark
  (124 dp) on `brand.launch` `#3A0CA8`, then the iOS `LaunchOverlay` zoom in the splash exit hook (hold 160 ms,
  breathe to 0.91 in 150 ms, zoom ×64 about `LelvoMark.zoomAnchor` in 420 ms with curve (0.6, 0, 0.84, 0.25), white
  mark fades in 140 ms, curtain fades in 80 ms, Photos settles from 1.08 in 550 ms after 320 ms). Cold start only, a
  tap skips (200 ms fade), Remove animations → short fade. Android 10–11: same picture as the window background, no
  new library. Plus an adaptive launcher icon (white camel on the violet→deep gradient) with a monochrome layer for
  themed icons, written by `Scripts/brand-assets.py` from `design/logo/mark.svg`. Preview:
  https://claude.ai/artifact/BJFDxnYW2p3KoSQXeWuXte
- 2026-11-11, A6 launch ✅: `brand-assets.py` now also writes the adaptive icon (with the themed-icon layer), the
  Android 12+ splash icon (288 dp canvas, mark 124 dp: measured 326 px = 124 dp at 420 dpi, same as the overlay), the
  Android 10–11 window background and `LelvoMark.kt`. `LaunchHost`/`LaunchOverlay` port the iOS opening; the system
  splash is removed the moment the overlay's identical first frame is drawn. Found on the emulator and fixed: the app's
  first frames stall (~700 ms, 36–41 skipped frames, debug build), so the zoom began half-way; the opening now holds
  its first frame until three frames in a row arrive on time (max 1.5 s). An offscreen layer with a clear blend was
  slow at ×64; it's now one even-odd path like iOS. Checked: cold start light and dark (breathe and zoom move every
  frame), Remove animations (straight to Photos), warm start (system splash only, no opening), icon in the app drawer.
  Not proven: tap to skip (adb can't time the tap). **To look at later:** ~700 ms of main-thread work on cold start
  (LelvoApp services and the first grid); measure in a release build before Phase E is ticked.
- 2026-11-11, B1 intro ✅: `IntroScreen` ports the six iOS pages (hook with the drifting photo wall and pop-in
  badges, storage full, features lit one by one, privacy flow and the `.cge` bubble, eight questions with four shown,
  your numbers) as a swipeable pager with a filled button and page dots, like Google Photos' first run. Shows before
  the phone step whenever signed out; Back from the phone step returns to the page left (iOS `introPage`). Android
  words: "phone" for `Device.name`, "Cloud storage 15 of 15 GB" for iCloud's meter, the phone's trash for Recently
  Deleted, "Allow all" for Full Access. `PhotoAccess` (data) gives full, partial (Android 14+), denied or not asked
  (Android doesn't say "not asked", so a flag kept across sign-out records it), the counts and the newest thumbnails;
  the manifest asks for `READ_MEDIA_*`, `READ_MEDIA_VISUAL_USER_SELECTED`, `ACCESS_MEDIA_LOCATION` (storage on 10–12).
  Found and fixed: dark mode drew black text (root wasn't a Surface); the wall redrew every frame behind the other
  pages and stalled their animations, so it pauses off page 1. Debug hook: `--ei lelvo.intro N`. Checked light and
  dark on every page. Page 3 shows the iPhone's own screenshots in the phone frame (owner: intro looks like iOS). Gap: the
  permission prompt, denied and partial states weren't run (the emulator already has access).
- 2026-11-11, B3 code-sent card ✅: `CodeSentCard` ports the iOS card (typing dots, the message lands, a light runs
  across five grey blocks, never digits; tap replays; Remove animations shows it at rest). Telegram: the service chat
  with an Open button in the card header (replaces the plain "Open Telegram" button); SMS: "Messages" in Google
  Messages' blue rather than iOS green. Not shown for other deliveries (call, flash call), like iOS. Dark in both
  themes, like the chat it pictures. Debug hook: `--es lelvo.signin code-telegram|code-sms|password` shows that step
  without signing out (Back closes it). Checked light (Telegram) and dark (SMS).
- 2026-11-11, onboarding looks like iOS (owner): the intro and every sign-in step copy the iPhone's layout, not a
  Material reinterpretation. `OnboardingKit` ports `OnboardingPage` (round Back, art or icon tile, 32 sp title, line,
  content, orange `ErrorBanner`, info, capsule button pinned on a solid strip), `PrimaryCapsuleButton` (strongest
  colour on the page: white on black in dark, black on white in light; solid when disabled; press shrink) and
  `OnboardingField`. Sign-in rewritten on it: phone (country row + dial code + number in one box, country search),
  code (title by delivery "Check Telegram"/"Check your messages"/"Enter the code", the key words highlighted, the
  card, digit boxes over a hidden autofill field, shake on a wrong code, "Didn't get it?" countdown, "Wrong number?
  +…"; Open goes to Telegram's code chat `tg://resolve?phone=42777`, then `tg://`), two-step password with show/hide
  and hint, other device, no account (Get Telegram → Play Store), email. The demo code step is the "other" delivery
  like iOS. Intro uses the same button and Back. Fixed: the intro phone frame was squeezed; it now keeps the
  screenshot's shape and is cut off by the card. Checked light and dark (code Telegram, code SMS, password).
- 2026-11-11, B4 library, unlock, new library, recovery key ◐: `LibraryScreens.kt` rebuilt on `OnboardingKit` from
  iOS `LibraryScreen`, `LibraryCard`, `PassphraseSetup`, `unlock` and `RecoveryKeyView`. Searching ("Looking for your
  library…", three tries two seconds apart like iOS, since the chat list is still syncing right after sign-in);
  "Couldn't check your channels" with Try again; "Welcome back" with selectable cards, rename (pencil on the selected
  card, Material dialog, `SetChatTitle`), "Start a new library instead" (its own page with Back, where iOS uses a
  sheet), "Use a different Telegram account"; first time "Your library" with the suggested name ("Lelvo Library 2"
  when taken, `LibraryNames` in `core/` with tests), passphrase twice (normalized like iOS, 10+ characters) and the
  orange warning with the tick. No longer opens a single library on its own: iOS asks with "Restore". Unlock: one
  field (Passphrase or recovery key, password autofill), orange error, Back forgets the choice. `createLibrary` in
  `LibraryService`: Argon2id first so a failure leaves no empty channel, then the channel with the header line in the
  description, the header message pinned (a failed pin is logged, the description still opens it), keys stored.
  Recovery key shown once in 13 groups, Copy marks the clip sensitive (the system preview shows dots) and clears it
  after two minutes if it's still the key, Back does nothing, "I've saved it" goes on. The setup state and the pending
  key live in `AppModel` (memory only), so rotating neither loses the passphrase nor cancels a library half-made.
  Debug hook: `--es lelvo.library found|found2|none|error|searching|unlock|recovery` (sample data, nothing reaches
  Telegram). Checked light and dark; wrong passphrase, rename dialog, create → busy → key → Copied. Not run: a real
  create, restore or rename on Telegram (needs the "Android test" library). "Standard" cards still show, and choosing
  one gives the "open it on iPhone or Mac" error.
- 2026-11-11, B5 scanning and photos step ◐: after unlock, "Restoring your library" with the mark breathing in a
  violet glow (still with Remove animations) and "N files found" rolling up, running `LibraryScanner.fullScan` (read
  only); then "Back up your photos" with what the scan found, the three features before asking, Allow access (the
  same one system prompt as the intro), then Full / Limited / No access (Open Settings; re-read on return) and "Start
  using Lelvo". A new library skips the scan (it's empty). `LibraryService.setupFinished` marks the end, kept with the
  library so choosing another goes through it again; installs already unlocked count as finished. A scan error offers
  Try again (iOS now does too). Gaps: `FirstBackupView` and
  `LibraryReadyView` need the first upload (Phase I); relinking restored items to phone photos is Phase C. Debug hook
  values `scanning` and `photos`. Checked light and dark, Full and No access.
- **Found 2026-11-11 (unexplained):** the emulator was signed out when checked at 17:56: TDLib starts at the phone
  step with a new, near-empty database, while the library choice, its keys and the database key file (16:35) are
  intact. No reset ran and `SessionWatch` saw no "logging out" (the log has nothing after 17:40's "session ready").
  The last launch before this session's first install (17:47) was signed in. Nothing in this session's diff touches
  `TdClient`, `SecretStore` or the key. Find out before Phase C: TDLib's own log (verbosity 2) on the next start, and
  whether a revoked session can reach the phone step without "logging out". If it can, the old library and index
  would stay for the next account.
- 2026-11-11, fix: after that unexplained sign-out the owner signed in again and the app opened the old library
  without asking for it or its passphrase (its choice and key were still stored). Now Telegram asking for a phone
  number while a library is still set up is handled like a session ended elsewhere: the library, its key and the
  index are removed from the phone, so signing in asks for both again. iOS now does the same (`AppModel`'s auth observer resets, keeping choices, on a phone-number request).
  `AppModel.forgetLibrary()` forgets the library on this phone; debug hook `--ez lelvo.forgetLibrary true` (works on
  a running app since `MainActivity` is `singleTop`; before, `am start` only brought the task forward). Real run so far: the
  library search found "Memvo Library" (end-to-end encrypted) on the real account; Restore opened the unlock step.
- 2026-11-11, Phase C ◐: the scanner now works like iOS `scanChannel`:
  - full or recent scan (from the last message read), one at a time, a full one once a week or on first use;
  - Recently Deleted and favorites and albums notes downloaded once, kept in the index (Room v2: `trash_notes`,
    `meta_notes`, `meta`, `no_backup`, auto-migration from v1) and applied after each scan;
  - a merge that keeps local state (phone link, Recently Deleted, an upload in progress), with favorites and albums
    notes applied in the same write (iOS writes twice, so its grid can briefly show the captions' favorites);
  - the index snapshot read on an empty index (1,124 items in 2 s on the real library), then a full scan behind it;
  - live new messages and deletes from other devices, batched over a second (`afterDeleting`, as iOS);
  - the index belongs to one library: a scan of another chat starts it from empty;
  - catch-up when Telegram is ready (launch, sign-in), then relinking to phone photos (`RestoreLinker`, MediaStore id
    from `l`, else name + capture second + shown size).
  Settings → Library: the libraries, current first; switch (passphrase checked before anything changes, unlike the
  old iOS order, which the iOS session has since fixed), rename, re-scan, new library. Telegram's sign-in states are
  now logged by name. Real library: 2,918 messages, 1,124 items, 1 incomplete, 0 unreadable; 1,075 shown, 49 in
  Recently Deleted, 49 favorites, notes 12 + 8, the same as Phase 0.
- 2026-11-11, Phase D ◐: cloud media from Telegram on the real library. The grid shows decrypted thumbnails; the
  viewer shows the thumbnail, then the screen copy of a big photo, then the photo; videos stream through a Media3
  `DataSource` over decrypted ranges (first frame in 0.6–1.0 s for 15–31 s originals). Logs "Photo timing" and
  "Video timing" lines like iOS. Gaps for Phase F: quality switch and stall fallback, Live Photo motion, zoom,
  download progress; a continuous TDLib download window like iOS `streamRead` if high-bitrate originals stall.
- **Found 2026-11-11 (now off):** the emulator had the owner's screen-time app's accessibility service on
  (`com.unlink/com.shahil.screentime.UnlinkAccessibilityService`). About 7 s after a photo opens it sends Back and
  scrolls, so the viewer closes and the grid moves by itself; Lelvo isn't doing it (no app code path, no adb input).
  Ask the owner before turning it off for testing. Also seen once: the grid moved after the first launch after an
  install; probably the same service.
- 2026-11-11, Phase E ◐: one timeline of phone photos (MediaStore) and cloud items, merged like iOS; the iPhone's tile
  overlays (badge top right on a dark circle, heart and length bottom left, nothing but the badge under 40 dp, the
  upload badge turning); filters and "What the icons mean"; the date scrubber; long-press and drag selection with
  Share (cloud photos downloaded and named like the original, through a share-only FileProvider), Favorite (the
  system's favorite prompt) and Delete (named warning for photos not backed up, then the system's trash prompt).
  Writes to a library now require it to be named "Android test" (`LibraryService.requireWritable`).
- 2026-11-11, Phase F ◐ (viewer): the iPhone's viewer the Google Photos way. Black in both themes; tap shows or hides
  the bars; top bar with date, time and the backup badge, the heart and ⋮ (Details, Share original for edited cloud
  photos); bottom row Share, Save (cloud only), Details, Delete. Swipe up for details, down to close, never while
  zoomed. Telephoto zoom (Apache-2.0, on the approved list) reads big photos in tiles from the file once zoomed in.
  Details sheet: date with its time zone, file (MP, size, length), codec and HDR, camera and exposure, place (opens
  the maps app: nothing is sent to a map service by Lelvo), folder on the phone, then Backup (badge with its meaning,
  uploaded, end-to-end encrypted, verified, last error). Save to phone (`PhoneSaver`): the original, decrypted whole,
  into `Pictures/Lelvo` or `Movies/Lelvo` hidden until written, removed if anything fails, space checked first, then
  linked to the item so the timeline shows one green tile. Share, favorite and delete now share code with the grid's
  selection (`actions/ItemActions.kt`). Video: own controls over Media3 (play, scrubber with keyframe seeks, times,
  mute, speed 0.5–2×, double tap on a side skips 10 s), a poster until the first frame, the quality pill ("1080p" /
  "4K") with switching at the same moment, the 3 s stall fallback on Automatic, audio focus and headphones, pause when
  the app leaves the screen. Live Photos: LIVE chip or long press plays the motion once with sound, behind the photo
  until its first frame (a SurfaceView ignores alpha), never on its own, so swiping doesn't download videos.
  - Proven on the emulator (real library): zoom and pan, details light and dark, save (86 KB and 3 MB originals),
    delete through the system prompt, the 4K video switched from 1080p to 4K at 16.3 s, first frames 0.2–1.5 s,
    Live Photo motion in about 0.2 s, Home pauses, swipe down closes.
  - Bugs found and fixed: a file saved without an EXIF date showed under Today (Android sets `datetaken` from the
    file when it's published and ignores an app's value), so the timeline now uses the backup's date for a linked
    photo with no capture date (`Gallery.merge`, tested); Save stayed after saving (would make a second copy); a
    paused video was black after returning to the app; a fast version counted as playable with some parts missing
    (now all of `sp`, like iOS `hasStreamingCopy`, tested).
  - Gaps: the phone's own Motion Photos; the frame strip above the scrubber (iOS `FrameStrip`); "Make fast version"
    needs uploads (I); saving keeps the original only (Android has no edit stack or Live Photos, so no edit or
    paired video); the stall fallback isn't proven on a slow network; pinch on a device.
  - **iOS and Mac bug found (told the owner, not copied):** the details sheet and the viewer's date use the phone's
    current time zone (`Format.date` in `Shared/Views/Components.swift`) and ignore the item's `tz`, so a photo taken
    abroad shows the wrong clock time. Android shows the time where it was taken, like Google Photos and Apple Photos.
- 2026-11-11, Phase F polish (owner: player like Google Photos, more room at the top, faster streaming, Live Photo
  glitch, green video):
  - Streaming: `TdFiles.streamRead` ports iOS `streamRead`: one continuous TDLib download runs ahead of the playhead
    (reads within 2 MB wait for it, small reads elsewhere fetch just their range, except for fast versions), waits on
    `updateFile`, gives up after 30 s; playback starts at 0.5 s buffered (iOS `startSoon`). Same 4K video: fast
    version's first frame 1.5 → 0.8 s, switch to 4K 4.0 → 3.1 s, no waits in 20 s of 4K; an unopened 4K video:
    1.2 s and 4.6 s (an 18 MB, 6 s original needs ~3 MB/s, more than Telegram sent here). Gap: TDLib keeps the
    streamed files in its cache; a size limit comes with Settings → storage (K).
  - Player: controls moved into the bottom panel, above the actions, on one fade: thin scrubber with the loaded part
    lighter, then play or pause, "0:15 / 0:28", speed and sound; a large play button in the middle only while paused.
    Top bar has room under the status bar and a longer fade.
  - Live Photo: the motion's first frames showed around the photo (the page is see-through there); the photo layer is
    now solid black until the motion has a picture.
  - Green and purple 4K original on the emulator: the emulator's own HEVC decoder (`c2.goldfish.hevc`), and only
    sometimes (the same video played right on the next try). Phones use their hardware decoder; check on a real
    Android phone before calling it fixed.
- 2026-11-11, video and photo speed (owner: 4K plays in slow motion, then green after a replay; photos slow to
  sharpen):
  - Green and purple blocks and slow motion were the emulator's pass-through decoders (`c2.goldfish.*`), which
    break 4K HEVC after a seek or replay. On the emulator the players now use Android's software decoders
    (`VideoDecoders`); phones keep their hardware ones. Same video: 0 frames dropped, replay in the right colours.
    The data was never wrong (CGFE is authenticated: a changed byte fails decryption). The log now names the decoder
    and counts dropped frames per video.
  - Play at the end paused instead of starting again; fixed.
  - Photos: opening one downloaded six files at once (its screen copy and original, and both neighbours' pages,
    which the pager builds ahead). Now only the page on screen downloads, the screen copy first, then the original,
    and neighbours load once it's sharp (iOS `NeighbourPrefetcher`). A file in one message downloads whole in one
    TDLib request (parallel pieces) and is decrypted from the phone, where iOS and Android read 8 MB ranges plus a
    header trip. Measured: screen copy 1.27 → 0.68 s, a 4.8 MB original 2.9 s (Telegram sent about 1.7 MB/s).
  - Not proven: 4K originals on a real Android phone (hardware decoder speed differs per phone). If a phone's
    decoder can't keep up, Automatic should stay on the fast version: check `MediaCodecInfo` performance points then.
- 2026-11-11, never-sharp photos and video swipes (owner):
  - **iPhone HEIC photos never turned sharp:** Coil decodes with Android's `ImageDecoder`, which refuses many of them
    ("getPixels failed with error invalid input"); `BitmapFactory` and the zoom's tiling read the same files. Coil now
    uses `BitmapFactory` (`imageDecoderEnabled(false)`). Logged now: "Photo timing: sharp after N ms", and a warning
    when the photo on screen isn't sharp 5 s after downloading.
  - **Video while swiping:** Media3's default SurfaceView sits outside the Compose layout, so during a swipe the video
    drew over the next page and lagged the finger. Players now use a TextureView (`res/layout/video_surface.xml`).
  - **Every phone:** hardware decoders first, with Media3's decoder fallback on; `VideoDecoders.canPlay` asks this
    phone whether it has a decoder for the original's format and size and, where it publishes speeds, one fast enough.
    If not, the fast version plays even with the Original setting (`VideoQualityPolicy.initial`, tested) and the menu
    shows "This phone can't play it smoothly". Still to prove on a real low-end phone.
  - **Flash when swiping fast between videos:** a screen recording showed the new video's first frame stretched across
    the whole screen for one frame, before the view knew the video's shape. The view now takes the shape from the
    backup before any frame (cloud videos), stays hidden behind the poster until its first frame has its real shape,
    and a quality switch keeps the last frame instead of going back to the poster. Checked frame by frame in a new
    recording of six fast swipes: no stretched frames.
- 2026-11-11, Phase F gaps closed:
  - **Motion Photos** (Android only; iOS has none): `MotionPhoto` in `core/` finds the MP4 inside a JPEG or HEIC by
    Camera XMP v1 (`MotionPhoto` item length), the older `MicroVideoOffset`, or Samsung's `SEFT` trailer
    (`MotionPhoto_Data`); every answer must start with an MP4 `ftyp` box, so a wrong offset never plays (6 tests).
    `MotionVideos` (data) copies the video to a small cache (newest 30) for Media3. The viewer checks only the page on
    screen (first 256 KB); a Motion Photo gets the MOTION chip and plays once on the chip or a long press, like Live
    Photos (`WithMotion` now serves both). Backed-up Motion Photos (kind `p`) are checked in the downloaded original.
    Proven on the emulator with a made-up Camera XMP v1 file: first frame in 156–237 ms, frames advance, released at
    the end. Not proven: real Pixel/Samsung files (real phone test), a backed-up one (needs Phase I), the grid has no
    motion mark (MediaStore doesn't say; reading every file's XMP for the grid would be too slow).
  - **Frame strip** (iOS `FrameStrip`): 8 keyframes, 160 px, made the first time the scrubber is dragged, shown above
    it with a white line at the position; cloud videos read the fast version where there is one, through a
    decrypting `MediaDataSource` in 512 KB blocks. Real library: 8 of 8 frames in 0.5 s for a 31 s video. Gap: demo
    videos (packaged assets) show no strip.
- 2026-11-11, Phase G ◐ (Collections, read side): the Collections tab like iOS `AlbumsView`, laid out the Google
  Photos way: Recent days (last 10 days with photos, a row of covers), Albums two across (Favorites first, then
  Lelvo's albums from the captions and albums notes, by name), "On this device" (MediaStore folders, Camera and
  Screenshots first, then the newest; Google Photos' name for them), Media types (Videos, Live Photos, Only in the
  cloud, Not backed up) and Recently Deleted with its count; See all for anything over four. A tap opens the photo grid
  for it (the Photos grid with Back, over the tabs, Google Photos style). `GalleryFilter` is now a sealed class (album,
  folder, fixed set of entries); `Collections.build` and `CloudTrash` in `core/` (8 tests). Recently Deleted shows the
  days left on each tile, newest deletes first.
  - Android differs from iOS on purpose: iPhone albums are Photos albums that Lelvo mirrors; Android has no shared
    user albums, only folders, so Lelvo albums and phone folders are separate sections (as Google Photos does).
  - Real library: Favorites 45, "shahil test" 7, WhatsApp 83, Recently Deleted 49 (same as the iPhone). Checked light
    and dark. Bug found and fixed: the folder row opened scrolled sideways (a folder arrived ahead of the first one).
  - Gaps: Recover / Delete in Recently Deleted and album edits write notes (Phase L, "Android test" only); Memories,
    Map (needs a map library issue); Documents and Receipts (needs on-device text recognition, Phase H/M); empty
    albums made on another device don't show until they hold a photo.
- 2026-11-11, Phase G Memories: `Memories` ported to `core/` with the iOS rules and numbers unchanged (bases, trips,
  on this day, recent, themes, selection, `placeCell`) and every iOS test case ported (16), plus `MemoryCards` with
  the iOS titles ("One Year Ago", "Trip to Goa", "Time in…", "Away, May 2024 – June 2024"). Collections shows a
  Memories row first (tall covers, Google Photos style), See all lists them as large cards (long press: Show all
  photos), and the gear opens Memories settings (same `memories.*` keys as iOS). The story player ports
  `MemoryStoryView`: 4 s per photo with a slow zoom (none with Remove animations), cross-fade, next two loading
  ahead, tap sides, hold to pause, swipe down to close, Show all, progress bars; a photo that won't load says so and
  the story moves on. Real library: 4 memories (Recent Highlights, two trips, one long stay) in 0.03–0.05 s; turning
  Trips off and on rebuilds them. Checked light and dark.
  - Gaps: no place names (trips read "Trip in February 2025" until search reads places, Phase H); phone-only photos
    have no location yet (MediaStore needs EXIF reads with `ACCESS_MEDIA_LOCATION`, Phase H); no themes or quality
    scores (needs an on-device image labeller: not on the approved list), so the Themes switch is hidden; the iPhone
    may make more or different memories for the same library because of those.
  - Test file left on the emulator for Motion Photo checks: `Pictures/MotionTest/PXL_20261111_120000000.MP.jpg`.
- **Next session (start here):**
  1. **Real Android phone check** (owner, later): everything listed in the Phase F notes, plus real Pixel and Samsung
     Motion Photos (MOTION chip plays), and Collections on a phone with many folders.
  2. Phase H (Search): `SearchService.swift`, `SearchMatcher.swift`, `SearchModel.swift`. It also brings place names
     (geocoder cache), which Memories' trip titles use, and phone photo locations.
  3. Phase G leftovers wait on other phases: Recently Deleted Recover/Delete and album add/rename/delete send notes
     (Phase L, "Android test" only); Map needs a map library issue.
- Still open (owner): approved library issue; an "Android test" library on the real account, made on the iPhone.
