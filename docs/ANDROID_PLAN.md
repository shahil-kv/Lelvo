# Android plan

The plan, the feature list and the progress note for the Android app, in one file. Tick boxes as steps land.
Decisions here are made; change them only on purpose, with the reason written down.

## Decisions

- **Same repository, `android/` folder.** The contract ([CLOUD_FORMAT.md](CLOUD_FORMAT.md)) and the test vectors
  ([test-vectors/](test-vectors/)) stay single copies; Android tests read them in place. No code is shared with Swift.
- **Native Kotlin.** Jetpack Compose and Material 3 (Expressive): Android's own look and gestures, not a copy of the
  iPhone screens. Same features, same words, Android's controls.
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
- **Testing never touches a real library.** Debug builds can sign in to Telegram's test servers (`use_test_dc`).

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
| Video | Media3 ExoPlayer (custom `DataSource`: byte range → TDLib → CGFE decrypt) |
| Index | Room |
| Background | WorkManager |
| Argon2id | argon2kt (native; Bouncy Castle's Java version can run out of memory at 256 MiB) |
| JSON | kotlinx.serialization |
| Tests | JUnit 5, Turbine |

AES-GCM, HMAC, PBKDF2 and SHA-256 come from `javax.crypto`; HKDF is ~20 lines on top of HMAC.

## Models

| Work | Model |
|---|---|
| Format and crypto port (Steps 2–3), library unlock (6), backup state machine (12), video `DataSource` (10), the cross-platform gate (16), stubborn bugs | Fable |
| Everything else: Gradle, screens, Room, WorkManager, wiring | Opus |
| Wide searches (Explore agent) | Haiku |

## Steps to the beta

Each step is one session and one pull request (after the previous one merges). "Done when" is the proof, not a build.

Every step follows the same loop (`.claude/rules/android.md`): read the iOS code and its fix history → read proven
open-source apps → write → compare iOS and Android again for missed cases and bugs. Each step keeps short notes under
it: **iOS edge cases carried over**, **learned from other apps**, **known gaps**.

### Step 0. Ready to start
- [ ] Umbrella issue with the libraries above, labelled `approved`.
- [ ] Android Studio installed (SDK, NDK 27 and CMake are already in `~/Library/Android/sdk`).
- [ ] A test Telegram account on the test servers, with a test library made by the iPhone app (Debug build).
- [ ] AGENTS.md: "Both platforms build" also covers `android/` once Step 1 lands.

### Step 1. Empty app that runs
- [x] Gradle project with the four modules, version catalog, minSdk 29, compileSdk 37, targetSdk 36.
- [x] `android-verify` skill: `./gradlew :core:test :app:assembleDebug`, logs in `build/android.log`.
- Done when: the empty Compose app opens on the emulator and `:core:test` runs.

### Step 2. Read the format (Fable)
- [ ] Caption codec (`CG1:` JSON, NFC), item kinds and roles, split-part layout, library header parsing.
- [ ] Metadata, favorites/albums and Recently Deleted notes (§7.1–7.3).
- Done when: `format1.json`, `metalog1.json` and `trashlog1.json` all pass.

### Step 3. Encryption (Fable)
- [ ] CGFE decrypt and encrypt, HKDF per-file keys, Argon2id (format 2), PBKDF2 and key check (format 1).
- [ ] Recovery key (base32, lenient input), passphrase forms from §6.1.
- Done when: `format1.json` and `format2-header.json` pass, and encryption with the vectors' fixed salt and nonces
  gives the very same bytes.

### Step 4. TDLib on Android
- [x] Build TDLib `18c8f7a0` for `arm64-v8a` and `x86_64`; `.so` files and `TdApi.java` in `:telegram`.
- [x] Build script checked in (`android/Scripts/build-tdlib.sh`); the binaries aren't committed.
- Done when: the app logs the TDLib version on the emulator and on a phone.

### Step 5. Sign in ← first thing you can try
- [ ] Phone number, code (showing where it was sent), two-step password, sign out. Session survives restart.
- [ ] Debug-only switch for the test servers. `api_id`/`api_hash` from `local.properties`, never committed.
- Done when: sign in on the test account, force-stop, reopen, still signed in.

### Step 6. Find and unlock the library (Fable reviews)
- [ ] Find the channel and pinned header; refuse unknown versions; plain library → message.
- [ ] Unlock with passphrase or recovery key; master key wrapped by an Android Keystore key.
- Done when: the iPhone-made test library unlocks; a wrong passphrase says so; the key survives restart.

### Step 7. Scan into the index
- [ ] Port the indexer: scan history → Room, then follow new messages. Apply notes (favorites, albums, deleted).
- Done when: the item count matches the iPhone app on the same library.

### Step 8. Timeline ← browse your library
- [ ] Material 3 grid, month/day headers, pinch between column counts, fast-scroll with date, decrypted thumbnails.
- Done when: smooth scrolling through the whole test library on a mid-range phone (no dropped-frame bursts in
  the profiler).

### Step 9. Photo viewer
- [ ] Swipe between items, zoom, screen copy (`d`) first then original, info sheet, share, save to phone.
- [ ] Live Photos: press to play the paired video.

### Step 10. Video (Fable designs the `DataSource`)
- [ ] Media3 player over ranged, decrypted reads; seek anywhere; fast version (`sp`) by default, quality switch,
  switch to the fast version after a 3 s stall, like the iPhone.
- Done when: a 1 GB split iPhone video starts in under 2 s from its fast version and seeks to the end.

### Step 11. Photos on this phone
- [ ] Permissions, including partial access and `ACCESS_MEDIA_LOCATION`. MediaStore scan. One timeline with
  "on this phone" and "in your Telegram library" states.

### Step 12. Back up (Fable reviews the state machine)
- [ ] Job queue in Room (pending → uploading → verified | failed), SHA-256 dedupe, encrypt, split, at most two
  uploads with the same pacing, `FLOOD_WAIT` honoured exactly, every part confirmed with its size.
- [ ] Thumbnail (`t`) and screen copy (`d`) like the iPhone writes.
- Done when: 200 test photos and videos back up; killing the app mid-way resumes with no duplicates; the bytes
  restored match the phone's file hash, location included.

### Step 13. Backup in the background
- [ ] WorkManager starts it (new photos, charging, Wi-Fi); long runs in a user-initiated job or a `dataSync`
  foreground service with a progress notification. Settings: Wi-Fi only, while charging.

### Step 14. Save to phone
- [ ] Save one item or everything, with the original date and location, into MediaStore.

### Step 15. Library setup and settings
- [ ] Create a new encrypted library on Android (header format 2), show and confirm the recovery key.
- [ ] Settings: backup, video quality, storage and cache, logs (redacted) and feedback, sign out.

### Step 16. Cross-platform gate (Fable)
- [ ] iPhone backs up → Android shows, plays and saves it, bytes equal.
- [ ] Android backs up → iPhone and Mac show, play and save it, bytes equal.
- [ ] Large split videos, Live Photos, Motion Photos, interrupted uploads, the same photo on both phones (one copy).
- [ ] Android 10, 13, 14, 15, 16 on real phones or emulators.

### Step 17. Beta
- [ ] Release signing, Play Console internal testing (or Firebase App Distribution), privacy policy covers Android.

## After the beta (iPhone features, in this order)

| Feature | Android approach |
|---|---|
| Favorite and albums editing (MetaSync) | Same notes, same 10 s pacing |
| Recently Deleted, removed from backup | Same trash notes |
| Free Up Space | Verify in Telegram, then `MediaStore.createDeleteRequest` (the system asks) |
| Make fast version on the phone | Media3 Transformer, HEVC 1080p 30 fps ~2 Mbit/s, `moov` first |
| Duplicates and similar photos | On-device only; needs its own issue for the model |
| Search | On-device text and labels; needs its own issue |
| Memories, map | Compose; map library needs its own issue |
| Keep a second copy | Storage Access Framework folder |

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
- **Next session:** demo mode first, so the screens can be built without a Telegram account:
  1. Step 7a: Room index (the `LibraryStore` tables the timeline needs), no channel scan yet.
  2. Demo mode, ported from `Shared/App/DemoMode.swift`: the same reserved number and code (read them there, don't
     copy them into docs), the same sample files (`iOS/DemoLibrary`, copied into the app's assets), nothing talks
     to Telegram, backup is simulated, sign out leaves demo mode. Debug and release, like iOS (App Review needs it).
  3. Then Steps 8, 9, the player part of 10, 15 and the backup screens against the demo library.
  Parts that need a real account wait for one real sign-in (`telegram.testDc=false`): Step 6 run, Step 7b channel
  scan, 10 streaming, 12, 16. Start from `android/`, read only this section.
- Step 0 still open (owner): approved library issue, test Telegram account on the test servers.
