# Open issues from testing (start here in a new session)

Every issue found while running [MANUAL_TEST_PLAN.md](MANUAL_TEST_PLAN.md), with how to fix it and how to prove the
fix. Fix them one by one, top to bottom. When one is done: mark it ✅ here with the date and commit, and add a row to
the test plan's run log.

Last updated 2026-11-18. Branch with the uncommitted test work: `docs/stability-test-plan`.

## How to work through this list

1. Read only the issue you are fixing and the files it names.
2. A bug found on one platform is checked and fixed on iPhone, Mac and Android in the same change.
3. Prove it: the "Done when" line. Run `Scripts/build.sh test`, `ios`, `mac`, and the `android-verify` skill.
4. Never back up the 40k seed: the "Lelvo 40k" simulator always launches with `-autoBackup NO -backupPaused YES`.

## Decisions waiting for the owner

| # | Question | Claude's recommendation |
|---|---|---|
| D1 ✅ yes (11-19) | Should each backup run retry, once, photos that failed only because of the network (I2)? | Yes. Today they wait for a tap on Retry. |
| D2 ✅ recommended wording (11-19) | 1.22: a photo whose Telegram messages were deleted shows "1 item couldn't be backed up / Retry". Is that wording right? | Say "1 photo is no longer in your Telegram library. Back it up again?"  ✅ fixed 2026-11-19 (0b8578c): header and button ("Back up again") on iPhone, Mac, Android. Retest: 1.22. |
| D3 | Run the Android 40k test with a real sign-in on an emulator (needs your login code)? | Yes, on a fresh emulator with automatic backup off. |
| D4 | Commit today's test work and open a PR (own files only)? | Yes, split into: fault injection + retry fix; scripts; UI tests; docs. |
| D6 ✅ yes | May Claude create a test library "Lelvo QA Test" on your account to prove I7 (a new private channel)? | Yes, it can be deleted after. |
| D5 | Mac 40k run? | Skip until iPhone and Android pass. |

## Issues

### I1 — Retries ignored the backoff inside one run ✅ fixed 2026-11-18 (uncommitted)

- **Seen:** L.4. Telegram unreachable for 40 s: all 5 attempts went in about 30 s, every photo was marked failed.
- **Fix done:** `waitForBackoff(of:isCancelled:)` in `Shared/Services/BackupEngine.swift`, called in each lane before
  `acquireLaneSlot`. Android already leaves not-due items queued.
- **Left:** commit it (D4). Add a core unit test that a retried item is not sent before its `notBefore`.

### I2 — Photos that failed in an earlier run need a manual Retry ✅ fixed 2026-11-19 (5dea7dc)

- **Seen:** L.4 follow-up. Attempts carry over between runs; after a network outage, those photos fail at once on the
  next run and stay failed until the user taps Retry.
- **Fix:** at the start of each run, move items that failed with a transient error (`notReady`, timeout, network)
  back to pending with attempts reset, once per item per day. Not for permanent errors (missing original, too big,
  channel gone).
  - iPhone/Mac: `BackupEngine.swift` run start + `JobQueue.swift` (store the last auto-retry date).
  - Android: `android/data/.../backup/BackupEngine.kt`, same rule.
- **Done:** `JobMachine.autoRetry` (Swift and Kotlin) at run start; the item keeps `transientFailure` and
  `autoRetriedAt` in its local JSON. Items that failed before this build have no flag and still need one Retry.
  Tests: `JobMachineTests.autoRetryOnlyTransientOncePerDay`, `backoffKeepsRetryWaiting` (the I1 leftover), Android
  `JobMachineTest` same names.
- **Retest:** L.4 (iPhone sim and Android), 1.22, T.1.
- **Done when:** unit test in `JobQueue` tests; rerun L.4 (`-QAOfflineFor 3 40`) with the outage longer than the
  backoff, kill, reopen: the photos back up without a tap.

### I3 — Android timeline jank about 11% on emulators

- **Seen:** `Scripts/android-jank.sh`, debug build, demo library. Pixel_9 emulator 11.5% janky, p99 150 ms;
  low-memory emulator 10.9%, p99 500 ms, 47 slow UI-thread frames. Goal: under 5%.
- **Not proven yet:** emulators and debug builds overstate this. First measure a **release** build on a real phone.
- **Fix if a real phone is over 5%:** profile with a Perfetto trace while flinging; usual suspects in
  `timeline/TimelineScreen.kt`: thumbnail decode on the main thread, unstable keys in `LazyVerticalGrid`,
  recomposition of headers, `DateScrubber.kt` recomputing on every frame. Add a Baseline Profile.
- **Done when:** release build on a real 60 Hz phone under 5% janky, p99 under 32 ms.

### I4 — Android 40k photos not tested (needs D3)

- **Seen:** the Android demo library only shows its 6 sample items, and the 2 GB emulator froze in system apps
  (Gboard ANR) with 40k photos, so nothing about Lelvo was learned.
- **Fix:** new emulator with 4 GB RAM and 8 GB storage; `Scripts/seed-library.py adb --serial …`; sign in with
  automatic backup off (debug intent extra, check it exists); measure first grid, cold launch, scroll with
  `android-jank.sh`, Backup tab counts.
- **Done when:** a run-log row with the same numbers as the iPhone 40k row (P.1, P.2, C.1).

### I5 — Android number field dropped digits (release build)

- **Seen:** sign-in phone field on the 2 GB emulator lost digits while typing under load.
- **May be the emulator** (Gboard was ANR'ing). Check on a real phone first.
- **Fix if real:** the field must not reformat on every keystroke from a background state; keep the raw text in
  `TextFieldValue` and format only for display (`VisualTransformation`).
- **Done when:** typing a full number fast on a real phone, 5 times, never loses a digit.

### I6 — "Create library" button covers the passphrase fields with the keyboard up (N.1) ✗ still open

- **Seen:** iOS New library sheet with the keyboard up; the bottom button covers the warning card.
- **Done:** the button was already in `.safeAreaInset`, but see-through; now `.background(.bar)` (iPhone/Mac sheet in `OnboardingView`). Android uses its own page with a fixed button (`NewLibraryPage`), check it on screen.
- **Still wrong (screenshot `build/qa/I6-keyboard-up.png`, 2026-11-18):** with the keyboard up the button bar sits over the "Repeat passphrase" field; the solid background only hides what's under it. Real fix: when a field is focused, scroll it above the bar (`ScrollViewReader` + `.scrollTo(focused)`), or put the button at the end of the scroll content instead of a bottom inset. Both the onboarding and the Settings sheets.
- **Was:** put the button in `.safeAreaInset(edge: .bottom)` or a scroll view that moves with the keyboard.
  Check the Mac and Android sheets too.
- **Done when:** screenshot on the smallest iPhone simulator with the keyboard up, nothing covered.

### I7 — UI tests can't type into passphrase fields (test tooling) ✅ done 2026-11-18

- **Seen:** 1.4. Password AutoFill stops typing reaching the fields under UI test.
- **Done:** `-QAPlainFields` (Debug only, `OnboardingField.contentType`) drops the content type; `RealAccountNewLibraryTests` passes it. Release check ☑ (no hook in Release).
- **Proven:** `RealAccountSettingsLibraryTests` created "Lelvo QA Test" (E2E) from Settings and switched back to "Lelvo QA" (202 items). What made typing work: tapping the eye (Show) first; `-QAPlainFields` alone did not. Its recovery key isn't exposed to UI tests, so that test channel is throwaway: the owner may delete "Lelvo QA Test" in Telegram (never "Lelvo QA" or the main library).
- **Was:** debug-only launch argument that turns off `textContentType(.newPassword)` for UI tests, or
  `-QAPassphraseFile` that fills the field from a file in `build/qa`.

### I8 — New features built but never seen on a screen

Revoked session / channel loss / disk-full stops (`RunStop`), full scan guard (`ScanPaging`), ignore list, year marks
on the scrubber, Mac drag-select, Loop videos, viewer Try again, ThumbHash placeholder. All compiled and unit-tested.
- **Done 2026-11-18:** switches `-QARevokeOnSend n`, `-QAChannelGoneOnSend n`, `-QADiskFullOnSend n` (Android `lelvo.faults` `revoke n`, `channel n`) and three UI tests. Engine ☑ for session and channel (run stops, nothing lost, next run backs up the rest). Disk full on a phone that isn't nearly full is retried per file, by design. UI ✗ → I9.
- **Was:** add fault switches `-QARevokedSession`, `-QAChannelGone`, `-QADiskFull` (and Android `lelvo.faults`
  equivalents) to `FaultInjection`, then run them on the "Lelvo QA" simulator like T.1. Screens by screenshot test.

### I9 — Backup tab hides why a run stopped ✅ fixed 2026-11-18 (uncommitted)

- **Seen:** session revoked and channel gone, "Lelvo QA" simulator. The engine is right: the run stops at once, the
  photo goes back to waiting, and the next run backs up the rest (log: "Backed up 5 items", 0 failed). But the Backup
  card shows "Backup complete, 7 items couldn't be backed up / Retry 7 failed" and never shows the stop message
  ("Telegram signed you out…"). A user would think the backup finished.
  The 7 failed are older items from earlier tests (L.4 before the fix, 1.22), not from this run.
- **Fix:** when the last run's summary has a `RunStopCause` message, the card shows that message as the title
  (warning style) instead of "Backup complete", with the right action: Sign in again / Open library settings.
  - iPhone/Mac: `Shared/Views/Backup/BackupDashboardView.swift` reads the summary error from `BackupEngine` (line ~735
    sets `summary.error`).
  - Android: `android/app/.../backup/BackupScreen.kt`, same rule from the engine's stop cause.
- **Fixed:** new "Backup stopped" header with the reason (iPhone `BackupDashboardView` `.stopped`, Mac `MainWindowView`, Android `BackupScreen` `stopReason`; Android keeps a stop summary even for runs the user didn't start). Both tests ☑ on the QA simulator. Android built, not yet seen on screen.
- **Was done when:** `RealAccountChangesTests/testI8_sessionRevoked` and `testI8_channelGone` pass (they look for the
  message). Run with `TESTS="testI8_sessionRevoked testI8_channelGone" bash build/qa/run-faults.sh`.

### I10 — Clear the old failed items on the "Lelvo QA" simulator (test hygiene)

7 failed items left over from earlier tests make the I8 tests' "nothing failed" check fail. Tap Retry 7 failed on that
simulator once, or make the check compare the failed count before and after.

### I11 — 10 duplicate uploads in the "Lelvo QA" library

- **Seen:** full scan on switch: "458 messages, 202 items, 0 incomplete, 10 duplicates". Probably from the kill-mid-backup and fault tests.
- **Check:** Backup → Duplicates on that simulator; find which test made them from the log (`Send started` for the same file twice). A duplicate upload breaks "never upload twice" (1.10 passed, so it may be the flood/offline tests).

### I12 — Switching or creating a library leaves backup paused for good

- **Seen:** 2026-11-18, Settings → New library ("Create and switch"), then switching back. Log: "Backup paused by
  the user" twice (the switch calls `BackupEngine.pause()`), and `backupPaused` stayed true. Automatic backup never ran
  again; new photos sat unqueued until the flag was cleared by hand.
- **Fix:** the switch pauses with a separate in-memory flag (or restores the earlier `backupPaused` value when the switch
  ends, also when it fails). Only the user's own Pause should persist. Check Android's switch too.
- **Done when:** switch library twice on the QA simulator, add a photo, it backs up automatically.

### I13 — Very long file name (228 characters) can't be backed up, with an unclear error ✅ fixed 2026-11-19 (131747b)

- **Seen:** Phase D.13. `D13-long…long.jpg` retried 5 times, then failed: "The operation couldn’t be completed.
  (PHPhotosErrorDomain error -1.)". Size 0 in the index. Unicode and emoji names were fine.
- **Likely cause:** the export/staging path uses the original file name, and 228 bytes + suffixes is over the 255-byte
  file name limit. Fix: stage under a short safe name (hash or asset id), keep the original name only in the caption,
  and cut it to fit when saving back. Check Android and Mac staging too.
- **Also:** a PhotoKit -1 that repeats should end as "This photo couldn't be read" (the ignore list), not a raw domain
  error.
- **Done when:** the same file backs up, and Save to phone gives a valid name.
- **Done:** `FileNames.safe` (Swift and Kotlin core) cuts names on disk to 160 bytes with the extension kept; used by
  every export staging path and Save to iPhone/Mac (`sanitizedFilename`) and Android Save to phone. The caption keeps the
  full name. Android staging already used ids. Not done: a repeating PhotoKit -1 still ends as the raw error (needs a
  device repro to tell it apart from a passing one).
- **Retest:** D.13, and Save to phone of that item.

### I14 — The photo's own time zone isn't kept (D.11) ✅ fixed 2026-11-19 (e15b995)

- **Seen:** photo taken 23:30 at +09:00 is stored with the device offset (+05:30, `tzOffsetMinutes` 330), not +09:00.
  The day is right here, but a photo taken at 01:30 abroad would land on the previous day on other devices.
- **Fix:** read `OffsetTimeOriginal` from the image metadata when present (iPhone/Mac at export time, Android from
  EXIF) and store that offset. Additive, no format change if `tz` already exists in the caption (check
  `docs/CLOUD_FORMAT.md`).
- **Done:** no format change: `tz` is already a caption field. Photos now store EXIF `OffsetTimeOriginal` (or
  `OffsetTime`), falling back to the device zone (iPhone/Mac read the exported file's properties; Android reads EXIF
  from the original). Videos keep the device zone.
- **Retest:** D.11.

### I15 — A photo added while Lelvo is open doesn't appear (3.20, simulator)

- **Seen:** 2026-11-18, "Lelvo QA" simulator, app open on Photos. `simctl addmedia` of one new photo: after 40 s it was
  not in the grid (Today still starts with the 11:55 photo) and nothing in the log (no "Looked for new photos", no
  backup). On the next launch new photos are found fine (Phase D).
- **May be the simulator:** `addmedia` from outside may not fire `photoLibraryDidChange` the same way the Camera does.
  Check on a real phone first (R8). Code: `GalleryModel` and `BackgroundTasks` both register a change observer.
- **Fix if real:** the observer must refresh the timeline and queue the new asset (debounced), also while a run is idle.
- **Not fixed 2026-11-19 (skipped):** both observers are registered; nothing in the code shows a bug, and the issue says to
  check on a real phone first (R8). Changing the observer blind risks extra library reads on every change.

### I16 — Largest text size: sign-in "Continue" can't be reached (10.15) ✅ fixed 2026-11-19 (intro "Everything in one app" page now scrolls; Android already did)

- **Seen:** 2026-11-18, "CI Clean" simulator, text size accessibility XXXL. On the phone number step the Continue
  button sits below the screen (y 992 of 874) and can't be scrolled into view, so sign-in can't go on.
- **Fix:** put the step's content in a ScrollView with the button in `.safeAreaInset(edge: .bottom)` (moves above the
  keyboard), or let the button scroll with the content. Check every onboarding step and the Android sign-in at
  font scale 2.0.
- **Done when:** `Scripts/../build/qa/tabs-tour.sh` "big" pass completes all 7 screens.
- **Not fixed 2026-11-19 (skipped):** the phone step already puts its content in a ScrollView with Continue in
  `.safeAreaInset(edge: .bottom)`, so the cause isn't visible in the code. It needs a run on a free simulator at XXXL to
  find what pushes the button off screen; none was free (UI tests were running). Retest after a fix: 10.15.

### I17 — "Beta" badge on Albums in Collections ✅ fixed 2026-11-19 (9c0d542)

- **Seen:** Collections tab shows "Albums  Beta"; the selection ••• menu also shows "Beta" under Add to Album and Favorite (`GalleryView.swift` ~435, ~447). The house rules say no "beta" in user-facing text, and the copy lint
  missed it (it is probably a separate badge string). Decide: drop the badge, or keep it on purpose and teach
  `Scripts/check-release.sh copy` to allow it.

### I18 — "1 items" in VoiceOver labels ✅ fixed 2026-11-19 (uncommitted; iOS, Mac, Android build clean)

- **Seen:** Collections row reads "Recently Deleted, 1 items" (UI test label, so VoiceOver says it too). Use the same
  singular/plural rule as the visible counts. Check other rows (albums, Smart Cleanup) and Android content descriptions.

### I19 — Fault UI tests pass when nothing was waiting to back up (test tooling)

- **Seen:** 2026-11-19. With every photo already backed up, `testT1_floodWaitHonoured` and `testL4_offlineMidRun`
  "passed" with 0 sends (log: "0 queued"), and the I8 tests failed for the same reason, not an app bug.
- **Fix:** run them through `build/qa/run-faults.sh`, which adds 6 new photos before each test. Better: the test
  fails when the app log shows no "injected" line for the run.

### I20 — Disk full: iPhone/Mac and Android behave differently ✅ fixed 2026-11-19 (9d3d083)

- **Seen:** 2026-11-19. iPhone/Mac stop the run on "out of space" only when the device has less than the margin free;
  otherwise the photo is retried 5 times and marked failed (one huge file must not block the rest). Android stops the
  run on any out-of-space error.
- **Decided 2026-11-19 (owner):** the iPhone rule on all three. Recommendation was: the iPhone rule, and on iPhone make that one file a permanent
  failure with "Not enough space for this file" instead of 5 retries.
- **Done:** Android already stopped only when nearly full (200 MB margin, as iOS). All three now share
  `RunStopClassifier.diskFullStopsRun`, and an out-of-space error with room left fails that one file for good with
  "Not enough space for this file." (no retries).
- **Retest:** the I8 disk-full rows (`-QADiskFullOnSend`): with the device not nearly full the faulted photos now end under Failed with "Not enough space for this file." instead of being retried, so row "I8 disk full (`-QADiskFullOnSend 2`)" expects that now. iPhone sim, Mac and Android.

## Needs a real phone (owner)

| # | Check | How |
|---|---|---|
| R1 | Scroll smoothness, big library, iPhone | Fling top to bottom and back. Or run `testP_scrollHitches` on the device for the hitch ratio. |
| R2 | Android jank on a real 60 Hz phone, ideally a 2–3 GB one | Install the release build, open the timeline, run `Scripts/android-jank.sh <serial>`. |
| R3 | 1.20 delete 3 photos while they are queued | Start a 20-photo backup, delete 3 in Photos. No crash; they don't stay "failed". |
| R4 | Live Photo round trip | Back up one, restore it, check it still moves. |
| R5 | Airplay mode for 1 min mid-backup | Backup carries on by itself afterwards. |
| R6 | @SpamBot after a big backup | Account is not limited. |
| R7 | I5 number field | Type the number fast 5 times. |
| R8 | I15 new photo while Lelvo is open | Open Lelvo, switch to Camera, take a photo, come back: it shows at the top and backs up. |
| R9 | Phase P on devices | Cold launch under 2 s, scroll, memory after 10 min, battery for a 1 h backup, cache size (P.1–P.10), iPhone, Android release build, then Mac. |
| R10 | T.4 end the Lelvo session from Telegram → Devices | Idle and mid-backup: clear sign-out message, nothing local wiped. |
| R11 | T.5, T.6 | Session name looks right; other chats' unread, mute and archive unchanged after a backup. |
| R12 | T.7, T.8, T.9 (test account) | Delete one item's message by hand, post junk in the channel, delete the channel; re-scan each. |
| R13 | T.11, T.12, T.13, T.14, T.15 | Two phones back up at once; 2 h unattended run; Telegram open during backup; VPN on; data use. |
| R14 | L.1–L.3, L.5, L.7, L.11–L.13 | Lock 10 min, call, Low Power Mode, restart, revoke Photos access, reopen after a day, heat, Mac lid closed. |
| R15 | D.1–D.7, D.9, D.14 | iCloud-optimized photo and video, RAW/ProRAW, HDR/ProRes/Cinematic/slo-mo, Portrait, panorama, burst, file over 4 GB, Android WhatsApp/SD folders. |
| R16 | 11.6, 11.8 | Back up on one phone while the other is open; the same photo on both phones gives one copy. |
| R17 | Decision D3 | See the table at the top. |
| R18 | Sign the Android emulator (Pixel_9) back in | Signed out since 2026-11-18. Needed for the Android fault runs (`build/qa/android-faults.sh`) and I4. |

## Progress of the test plan (2026-11-18)

- About 90 checks done of about 470 (most of the rest are by hand on a device or Pro).
- Done by Claude: Phase 0 (automated gate), Phase 1 core on simulator (1.2, 1.4, 1.6, 1.9, 1.10, 1.12, 1.18, 1.19,
  1.21, 1.22), Phase T (T.1), Phase L (L.4), Phase 7 (7.3), Phase P on iPhone simulator (P.1, P.2), Phase C (C.1),
  automation A1, A2, A4, A10, A11 (sim part).
- Next phase for Claude: **Phase 3** (gallery) and the rest of the simulator phases. Fixes wait until the whole test pass is done (owner, 2026-11-18). (fault switches for the stop conditions), then Phase D (media edge cases) on the
  simulator, then Phase 3 gallery checks by screenshot.

## What is left to finish the stability work (order)

1. **Fix list:** I9 (in test), I2 after D1, I7, I6, then the I8 screens by screenshot. Claude, one after another.
2. **Simulator phases Claude can still run:** Phase D media edge cases (HEIC, ProRAW, long video, slo-mo, screenshots,
   huge files over 2 GB split), Phase 3 gallery, 4 viewer, 5 collections, 6 search, 8 Free Up/restore, 10 settings,
   11 sync between two simulators, 14 copy/compliance. Each adds rows to the run log and issues here.
3. **Android parity runs:** the same fault tests through `lelvo.faults` on an emulator, and I4 (40k) after D3.
4. **Owner on real phones:** R1–R7, plus Phase 9 (background, battery) and M (Mac) by hand.
5. **Ship:** commit in small PRs (D4), CodeRabbit review, TestFlight build, the real-phone list again on that build.

Done means: every row in Phases 0–15 is ☑ or has an open issue here, no S1/S2 issue is open, and R1–R7 pass on
the TestFlight build.
