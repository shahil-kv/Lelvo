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
| Item count after notes (Recently Deleted, favorites, albums) | Notes applied | The iPhone's photo count | Phase C |

A failure here stops the work until it's fixed; nothing in A–N starts on a base that doesn't match.

## Phases

Each row is one feature; a phase is a few pull requests. Status: ✅ done, ◐ part done, blank not started.

### Phase A. Foundation (architecture)

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Modules: core / telegram / data / app | `Packages/LelvoCore`, `Shared/Services` | Gradle modules | ✅ |
| Format and crypto (captions, header, CGFE, keys) | `LelvoCore/Format`, `Crypto` | `core/`, 66 tests on the shared vectors | ✅ |
| TDLib built for Android | `TDLibKit` in `project.yml` | `android/Scripts/build-tdlib.sh` | ✅ |
| Services container | `Shared/App/AppEnvironment.swift`, `AppModel.swift` | `LelvoApp` holds services; an `AppModel` state holder for the shell | ◐ |
| Theme and colours | `design/tokens.json`, `docs/DESIGN.md` | Lelvo colour scheme, no dynamic colour; tokens script writes `LelvoColors.kt` | ✅ |
| App shell: 4 tabs, Settings, navigation | `iOS/Views/RootView.swift`, `SettingsButton.swift` | Bottom navigation bar, gear on every tab, demo banner on every tab, Back returns to Photos | ✅ (Collections, Search, Backup are placeholders until G, H, I) |
| Preferences | `Shared/Services/Preferences.swift` | `Prefs`: same keys and defaults; iPhone-only keys left out with the reason; grid columns kept | ✅ |
| Logs with redaction | `AppLog.swift`, `LelvoCore/Support/Redactor.swift` | `AppLog` in `data/`, `Redactor` port in `core/` with its tests | |
| Toasts | `Shared/Views/Toast.swift` | Snackbar host in the shell | |
| Launch screen and brand mark | `Shared/Views/Brand/` | Splash screen API, vector mark | |
| Review demo | `Shared/App/DemoMode.swift` | `DemoMode` | ✅ |

### Phase B. Onboarding and sign-in

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Intro pages | `Shared/Views/Onboarding/IntroView.swift` | Horizontal pager, same pages and words | |
| Phone, code, two-step password, other device, no account | `OnboardingView.swift`, `TDService.swift` | `SignInScreen` | ◐ (needs one real sign-in) |
| Where the code was sent | `CodeSentCard.swift` | Card on the code step | |
| Session ended elsewhere | `LelvoCore/Support/SessionWatch.swift` | `SessionWatch` port | ✅ (logic), screen to do |
| Choose library, unlock, recovery key | `LibraryService.swift`, `EncryptionSettingsView.swift` | `LibraryScreens` | ◐ (needs real run) |
| New library with recovery key shown and confirmed | `OnboardingView.swift` (`.recoveryKey`), `PassphraseBox.swift` | Header format 2 writer, key screens | |
| Scanning and "library ready" | `LibraryReadyView.swift` | Progress screen, item count | |
| Photo permission (full, partial, location) | `OnboardingView.swift` (`.photos`), `PhotoLibraryService.swift` | `READ_MEDIA_*`, partial access (Android 14), `ACCESS_MEDIA_LOCATION` | |

### Phase C. Library and index

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Room index | `LelvoCore/Index/LibraryStore.swift` | `items` table | ✅ (7a) |
| Channel scan into the index, snapshots | `LibraryIndexer.swift`, `IndexSnapshot.swift`, `LibraryService.swift` | `core/` indexer, `data/` scanner | |
| Follow new messages | `LibraryService.swift` (updates) | TDLib update flow | |
| Favorites, albums, Recently Deleted notes | `MetaLog.swift`, `TrashLog.swift`, `CloudTrash.swift` | Apply notes in the index | |
| Link cloud items to phone photos | `RestoreLinker.swift`, `Deduplicator.swift` | By SHA-256 and MediaStore id | |
| Re-scan, rename, switch, new library | `LibraryService.swift`, `SettingsView.swift` | Settings rows | |

### Phase D. Reading media from Telegram

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Ranged, confirmed downloads | `MediaReader.swift`, `TDService.swift` | `TdClient` download + range reads | |
| Thumbnail, screen copy, original | `CloudMediaService.swift`, `ScreenCopy.swift` | `data/` media service | |
| Thumbnail cache | `ThumbnailPipeline.swift`, `LelvoCore/Cache/LRUDiskCache.swift` | Coil fetcher (TDLib → CGFE decrypt) + disk cache | |
| Video streaming, quality, fast version | `StreamingAsset.swift`, `CloudVideo.swift`, `VideoQuality.swift`, `MovieLayout.swift` | Media3 `DataSource` over decrypted ranges | |
| Resume where you left off | `Shared/Support/PlaybackPositions.swift` | Same rule, prefs | |

### Phase E. Photos tab

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Grid with day / month / year, pinch | `NativePhotoGrid.swift`, `GalleryModel.swift`, `GridSnapshot.swift` | `TimelineScreen` | ◐ |
| Phone photos and cloud items in one timeline | `GalleryModel.merge`, `PhotoLibraryService.swift` | MediaStore scan + index | |
| Status badges and "what the icons mean" | `NativePhotoGrid.swift`, `GalleryView.swift` | Cell badges, help sheet | |
| Date scrubber | `NativePhotoGrid.swift`, `VideoNavigation.swift` | Fast-scroll thumb with date | |
| Filters: videos, Live Photos, favorites, only in Telegram, not backed up | `GalleryModel.swift` (`Filter`) | Filter chips in the top bar menu | |
| Select, swipe to select, select all | `SwipeSelection.swift`, `GalleryView.swift` | Long-press + drag selection | |
| Actions: back up, share, favorite, add to album, delete (phone / Telegram / everywhere) | `GalleryActions.swift`, `GalleryView.swift` | Bottom action bar, dialogs, system delete prompt | |

### Phase F. Viewer

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Swipe between items | `ViewerView.swift` | Pager | ◐ |
| Zoom, double tap | `ViewerView.swift` | Telephoto | |
| Screen copy first, then original | `CloudMediaService.swift` | Two-step load | |
| Info: date, place, camera, size, where it is | `ViewerView.swift` (Info), `ExtraMetadata.swift` | Bottom sheet | |
| Share original, save to phone, favorite, delete | `ViewerView.swift`, `GalleryActions.swift` | Top bar and bottom bar | |
| Live Photos (press to play), Motion Photos | `ViewerView.swift` | Media3 with the paired video | |
| Video player: speed, quality, sound off on close | `CloudVideo.swift` | Media3 player UI | ◐ (demo clips) |

### Phase G. Collections tab

| Feature | iOS source | Android | Status |
|---|---|---|---|
| Albums from the phone and from your library | `AlbumsView.swift`, `AddToAlbumView.swift`, `MetaSync.swift` | MediaStore buckets + Lelvo albums | |
| Add to album, rename, delete album | `AddToAlbumView.swift`, `AlbumsView.swift` | Dialogs | |
| Favorites, videos and other smart rows | `AlbumsView.swift` | Same rows | |
| Recently Deleted (30 days, restore, delete now) | `RecentlyDeletedView.swift`, `TrashGrid.swift`, `TrashSync.swift` | Grid + actions | |
| Memories | `MemoriesView.swift`, `LelvoCore/Support/Memories.swift`, `MemoriesSettingsView.swift` | Cards, same rules | |
| Map | `PhotoMapView.swift` | Needs a map library issue | |

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
- **Next session (start here):** Phase A, next unticked row: logs with redaction (`AppLog` + `Redactor` port with its
  tests from `LelvoCore/Support/Redactor.swift`), then snackbars (A5), then launch screen with the brand mark (A6),
  then the services container (A7). Before each screen, look at Google Photos' version first. Then Phase B.
  Nothing from this branch is committed yet (owner hasn't said); ask once at the start.
- Still open (owner): approved library issue; an "Android test" library on the real account, made on the iPhone.
