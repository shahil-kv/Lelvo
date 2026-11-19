# Automatic backup on Android: hardening plan

Status: draft for the owner's approval, 2026-11-14. iPhone version shipped in #125.

Android already has automatic backup (`docs/ANDROID_PLAN.md`, Phase J). This plan makes it **reliable**: new photos go
up soon after they're taken, a large backlog finishes without the charger, and when Android or the phone maker blocks
Lelvo, the app says so and shows the fix. It's written so another model or contributor can build it phase by phase
without guessing. Read "Before you start" first, then do **one phase at a time, in order**. Each phase lists the
files, the exact change, the tests, the device check and when it's done.

---

## Before you start (read this, every session)

1. Read `AGENTS.md` (the non-negotiables), `android/CLAUDE.md` and `.claude/rules/android.md`. This plan never
   overrides them.
2. Read these files before you touch them (every phase uses them):
   - `android/app/src/main/kotlin/app/lelvo/android/background/BackupScheduler.kt`: the four unique works
   - `android/app/src/main/kotlin/app/lelvo/android/background/BackupWorker.kt`: one worker, `KIND` picks the job
   - `android/app/src/main/kotlin/app/lelvo/android/background/BackupNotifications.kt`
   - `android/data/src/main/kotlin/app/lelvo/data/backup/BackupEngine.kt`: `run(...)` (~line 290), `blocker()`
     (~line 170), `waitForFloodPause()` / `holdFor()` (~lines 408–450), `Summary` (~line 110)
   - `android/data/src/main/kotlin/app/lelvo/data/Prefs.kt`: keys and defaults (`autoBackup` is `false`)
   - `android/app/src/main/kotlin/app/lelvo/android/LelvoApp.kt`: `schedule(...)` at launch, `startBackup`, `isOnScreen`
   - `android/app/src/main/kotlin/app/lelvo/android/library/FirstBackupScreen.kt`: the last onboarding screen
   - `android/app/src/main/kotlin/app/lelvo/android/backup/BackupScreen.kt`, `settings/SettingsScreen.kt`,
     `settings/BackupOptionsScreen.kt`
   - The iPhone code each phase copies: `Shared/Services/BackgroundTasks.swift`, `Shared/Services/BackupNotifications.swift`,
     `Packages/LelvoCore/Sources/LelvoCore/Backup/BackgroundRuns.swift`, `iOS/Views/Settings/BackgroundLabView.swift`
3. One branch from `main`: `android/auto-backup`. One commit per phase, on that branch. Stage files by path, never
   `git add -A`. Never commit `.cursor/`, `marketing/` or `android/local.properties`.
4. Checks after every phase (all must pass; never print a whole Gradle log):
   ```sh
   cd android
   ./gradlew :core:test > ../build/android-test.log 2>&1; tail -15 ../build/android-test.log
   ./gradlew :app:assembleDebug > ../build/android.log 2>&1; grep -E '^e: |^w: |What went wrong' -A4 ../build/android.log
   ```
   Then the `android-verify` skill (install on the `Pixel_9` emulator with `adb install -r`, **never** uninstall or
   clear data: the emulator is signed in and the owner must not log in again).
5. Debug builds use Telegram's test servers, and writes go to the "Android test" library only. Never test on the
   owner's real library.

### Rules that matter most here

- **Never lose a photo.** Every background path calls `app.backup.run(...)`; an item is only backed up when Telegram
  confirmed every part. A job Android stops half-way leaves the item queued.
- **Respect Telegram.** At most two uploads (`MAX_CONCURRENT_UPLOADS`), honour `FLOOD_WAIT` exactly **across
  processes** (phase 1 fixes a gap here). More jobs must never mean more parallel uploads: the engine's `running`
  gate stays the only way in. The worker runs in the app process and shares that one engine, so do not add a second
  lock. (Ente needs a database lock because a background Flutter engine and the UI engine both upload. Lelvo does not.)
- **Respect the user's settings** everywhere: automatic backup, Paused, Wi-Fi only, Only while charging, photos on
  mobile data.
- **No secrets in logs** (`AppLog` only; no file ids, names, phone numbers).
- **Main thread for UI only.** WorkManager workers already run off it; MediaStore, Room and TDLib stay on `Dispatchers.IO`.
- **No new dependencies.** WorkManager 2.11.2 is already approved. Everything here is platform API.
- **No restricted permissions.** Don't add `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `SCHEDULE_EXACT_ALARM` or
  location. Open the system settings screens instead (phase 6). Google Play restricts the first one to a short list of
  app types, and we don't need it.
- **User-facing words:** short sentences, plain words, no exclamation marks. Say "your Telegram library". Use the copy
  in this plan unless the owner changes it.

---

## What's wrong today (found in the code, 2026-11-14)

| # | Problem | Where | Effect |
|---|---|---|---|
| 1 | The new-photos trigger is armed again only **after** a run ends | `BackupWorker.doWork` `finally` | Photos taken during a run (up to 10 min) aren't in that run's list and don't fire a trigger: they wait for the next photo, the charger or an app open |
| 2 | The listener and the uploader are one request, with the network and charging constraints on it | `armNewPhotos` | With "Only while charging" or Wi-Fi only, the trigger waits with the run; Immich split these in 2022 for the same reason |
| 3 | A backlog only drains on the charger | `OVERNIGHT` has `setRequiresCharging(true)` always | 2,000 waiting photos on battery stop after one 10-minute run; nothing continues until the phone charges or Lelvo opens. iOS fixed this in its phase 5 |
| 4 | `FLOOD_WAIT` is kept in memory only | `BackupEngine.pausedUntil` | Android ends the process, a new worker starts in a new process and sends before Telegram's wait is over. Breaks non-negotiable 3 |
| 5 | Opening Lelvo doesn't start a backup | no `AutoStart` | iOS backs up on open (#125); Android waits for a trigger |
| 6 | Automatic backup is off and nobody is asked | `Prefs.autoBackup = false`, onboarding has no switch | Most people never get automatic backup |
| 7 | No record of what ran or why it stopped | only log lines | Nobody can tell whether background backup works on a given phone |
| 8 | Battery restrictions, Samsung "sleeping apps", force stop and "Selected photos only" access are invisible | nowhere | Backup silently stops; this is the top support question for Ente, Immich and Nextcloud |
| 9 | `dataSync` foreground runs have a 6-hour daily limit on Android 15+ (we target 36) | `userRun` | A very large first backup is stopped by Android; nothing says why |
| 10 | No stuck reminder or overnight summary | `BackupNotifications.kt` | iPhone has both |

---

## How the proven apps do it (and what we copy)

- **Immich** (open source, `immich-app/immich`, code read 2026-11-14): the listener/uploader split is real and we
  copy it, with the corrections under "Edge cases" below. Their current observer still waits for the charger when
  that setting is on, they cancel the background worker while the app is open, and a large file starts over because
  an upload does not resume. → phases 2, 3, 4.
- **Nextcloud** (open source, `nextcloud/android`, code read 2026-11-14): years of flaky auto upload, and they are
  still shipping worker-policy fixes in 2026. What they got right, and the traps, are under "Edge cases". → phases
  2, 3, 6.
- **Ente** (open source, `ente-io/ente`, code read 2026-11-14): they have **not** solved background backup for every
  phone. Details and what we copy are under "What Ente's code does" below. → phases 3, 4, 6.
- **Android's own rules** (developer.android.com):
  - Regular jobs (WorkManager) stop after **10 minutes**; Android 16 also puts a runtime quota on apps in the active
    bucket and on jobs started while the app is on screen. → design: many short jobs chained, never one long one.
  - Apps can't start a foreground service from the background (Android 12+). Expedited work is the replacement, with
    `RUN_AS_NON_EXPEDITED_WORK_REQUEST` as the fallback. Expedited work can't have charging or idle constraints.
  - `dataSync` foreground services get **6 hours per 24 hours** on Android 15+ (reset when the user opens the app).
  - Force stop cancels every job until the app is opened again. Some makers treat swiping from Recents as a force stop.
  - `adb shell cmd jobscheduler`, `dumpsys jobscheduler` and Android 16's `getPendingJobReasonsHistory` show why a job
    hasn't run. → phase 1 and the test section.
  - User-initiated data transfer jobs (Android 14+) are for long transfers the user starts; no Jetpack support yet.
    Not now (see "Not doing").

### What Ente's code does (read 2026-11-14)

Ente Photos is Flutter, in `ente-io/ente`. Two schedulers exist. Users get the old one.

- **What ships** (`mobile/apps/photos/lib/utils/bg_task_utils.dart`): a WorkManager refresh every 15 minutes that needs
  a network and nothing else (not charging, not idle, not expedited), plus a processing job every 2 hours that
  requires charging **and** the device to be idle. The Dart timeout on Android is 1 hour, so it never fires before
  WorkManager's 10-minute kill. The next try is the next periodic slot, which Android may push back by hours.
- **The newer plugin** (`plugins/ente_background_manager`, `BackgroundRuntime.kt`): refresh every 15 minutes with a
  **9-minute budget**, processing every hour while charging, unique work replaced with
  `ExistingPeriodicWorkPolicy.UPDATE`, and any frequency under 15 minutes refused (`TaskConfiguration.kt`). It is
  installed in `EnteApplication.kt` only when the remote flag `internalUser` is true. Everyone else never runs it.
- **New photos** are noticed only inside a living process (`LocalSyncService`: `PhotoManager.addChangeCallback`,
  500 ms debounce). That callback dies with the process. There is no MediaStore trigger left armed. A photo taken
  while Ente is dead waits for the periodic job or for someone to open the app. This is the gap Immich closed and
  phase 2 closes. Do not copy Ente's listener.
- **Opening the app** stops the background engine (`BackgroundRuntime.foreground()`), then the foreground process
  syncs at once and every 5 minutes (`kFGSyncFrequency` in `main.dart`). They stop the background engine because the
  two Flutter engines would upload the same file. Lelvo has one process and one `BackupEngine`. Phase 4 does not
  cancel the automatic run: the user run waits on `activity` (`BackupWorker.userRun`), shows the notification, and
  takes whatever is left. The automatic chain does not also book a next run while that user work is queued. Do not
  add Ente's SQLite upload lock.
- **A large backlog** is "Backup mode": keep Ente on screen, dim it, plug in. That screen is iOS-only
  (`backup_settings_screen.dart`). They do not chain short jobs after a run stops. Phase 3's chain is the Android
  version of the same need, and it works with the app closed.
- **Resuming a file:** upload locks and multipart part tags live in SQLite, and a heartbeat in SharedPreferences
  (5 seconds) tells the next process the other engine is dead. Lelvo already puts an item back on the queue when a
  process dies (`ItemStatus.Uploading` → interrupted) and deletes a half-sent message. The only wait that must be
  written down is `FLOOD_WAIT` (phase 1). Do not add their lock database.
- **Battery, Samsung, Xiaomi:** no code. No `isIgnoringBatteryOptimizations`, no settings intent, no maker strings.
  The help page tells people to set battery to Unrestricted, and still says background sync is not consistent on
  some Android devices. Reports through 2026, including a stock Pixel with Unrestricted, say photos wait until the
  app is opened. Their missing in-app Fix is why phase 6 exists. Do not drop the card because Ente has none.
- **Android 15's 6-hour limit:** avoided, not handled. Background backup is a normal job of a few minutes, not a
  `dataSync` foreground service, so the quota does not apply. They never read a foreground-service timeout. Phase 7
  still has to, because a backup the user started does use that service.
- **What we copy:** stop a background upload at 9 minutes and book the next run while the process is healthy
  (phase 3); `UPDATE` for the periodic safety net, and never `requiresDeviceIdle` (phase 3); the frequent job on
  battery and the heavy job on the charger (phase 3); one engine, so opening the app waits for the run already
  going and then continues it as a user run (phase 4). **What we do not copy:** the in-process photo listener,
  Backup mode instead of a chain, killing the background run on open, a second upload lock, or a docs-only battery
  fix.

### Edge cases Immich and Nextcloud already hit (code read 2026-11-14)

Neither app has finished this. These are the cases their code and bugs already paid for. Follow them where they
worked, and do not copy the part that is still broken.

**Copy**

- Re-arm the listener **before** any upload, with `APPEND_OR_REPLACE`. Immich's `MediaObserver` and Nextcloud's
  `ContentObserverWork` both re-arm with `REPLACE`. Nextcloud's own comment on the upload job: replacing a running
  unique work cancels it mid-upload. Immich calls `REPLACE` at the start of the observer, so the observer can be
  cancelled before it finishes. `APPEND_OR_REPLACE` queues the next listener behind this one.
- The trigger is a signal, not the list of files. Nextcloud writes the changed URIs and, if that fails, scans the
  whole folder ("fallback to insert all db entries to not lose files"). `enqueueNew()` always scans MediaStore. Do
  it even when `triggeredContentUris` is empty. Their observer skips the upload in that case.
- Scan **before** deciding there is nothing to upload. Nextcloud's comment: files added since the last run stay
  invisible if the "nothing to do" check runs first.
- One worker uploads the whole queue. Nextcloud chained a job per batch and hit Android's limit of about 100
  scheduled jobs ([#15214](https://github.com/nextcloud/android/issues/15214)). Never enqueue a job per photo.
  There is one `AUTO_RUN`.
- Leave `BackupScheduler.schedule()` in `LelvoApp.onCreate`. Immich's `ImmichApp` enqueues a backup 15 seconds
  after any process start with no UI, because a kill drops the next content trigger until something re-arms it.
  Our `onCreate` already calls `schedule()`, so a worker that starts the process re-arms the trigger. Do not move
  that call to the activity.
- Record the new photos even when the phone is saving battery. Nextcloud's observer returns without writing them
  down while power saving is on, and hopes a later periodic scan finds them. We queue them and let `AUTO_RUN`'s
  constraints wait.
- Do not cancel the background upload because the app opened. Immich (`BackgroundEngineLock`) and Ente both do.
  The upload then dies when the user leaves, because it lived in the UI engine. Ours lives in `BackupEngine`.
  Phase 4's device check (Home, screen off, a large video, then swipe from Recents) is the regression they still
  have ([Immich #31042](https://github.com/immich-app/immich/issues/31042)).

**Do not copy**

- Immich's charging constraint on the listener (`MediaObserver` still calls `setRequiresCharging` when that setting
  is on). Network is already off it. Charging must be off it too, or "Only while charging" hides new photos until
  the next one is taken on power. Phase 2.1.
- Their upload worker as a `dataSync` foreground service. Immich promotes to one, for up to 20 minutes
  (`maxMinutesArg = 20`), **only if battery optimisation is already off**. Otherwise the job dies at 10 minutes.
  That foreground time counts toward Android 15's 6 hours. Our automatic runs stay normal 9-minute jobs and do not
  spend that quota. The user-started run is the one that does (phase 7).
- Expedited work together with "battery not low". Nextcloud's expedited file upload sets network constraints only.
  Immich never expedites the backup worker. Phase 2.3 already drops battery-not-low on the single expedited
  request. The 15-minute chain stays a normal job.
- Nextcloud's 5 second / 10 second trigger window, and Immich's user-chosen delay. A burst that short starts a run
  often enough to trip `FLOOD_WAIT`. Keep 30 seconds / 3 minutes.
- Nextcloud's `MediaStore.Files` trigger. They sync arbitrary folders. We watch images and videos only, or every
  download would wake a backup.

### What the user gets after this plan

- Automatic backup is **on** after onboarding (they see it and can turn it off).
- New photos go up within a few minutes, on battery too, unless "Only while charging" is on.
- Opening Lelvo backs up what's waiting, with the progress notification while it continues in the background.
- A big backlog keeps going in short background runs until it's done; on the charger it goes faster.
- If Android or the phone maker blocks Lelvo, the Backup tab says so in one line with a **Fix** button.
- Optional: a morning summary and a reminder when backup has been stuck for days.

**What we don't promise:** "always instantly". On some phones (Xiaomi, Huawei, some Samsung settings) the maker
blocks background work until the user changes a setting. The app tells them which one.

---

## Target design

```
MediaStore change ──► NEW_PHOTOS (trigger only, no constraints, ~seconds)
                          │ 1. re-arm the trigger first
                          │ 2. queue new photos (cheap MediaStore read)
                          ▼
                       AUTO_RUN (unique, KEEP) ── constraints: network rule, charging if chosen, battery not low
                          │ expedited when allowed, else a normal job
                          │ stops itself at 9 min (do not wait for Android's 10-minute kill)
                          │ items left, "out of time" ──► AUTO_RUN again in 15 min (or after FLOOD_WAIT)
                          ▼
                       done ── nothing left: stop the chain
SAFETY_NET (periodic 1 h) ── if items are waiting and no AUTO_RUN is queued: enqueue AUTO_RUN
OVERNIGHT (periodic 4 h, on charger) ── unchanged, plus search indexing
App opens ──► AutoStart: something waiting → user-style run with the progress notification
```

All runs go through `app.backup.run(...)`. The engine's gate stops two at once, so a second request returns
"already running" and is dropped.

---

## Phases

All nine phases land on one branch (`android/auto-backup`), one commit per phase, with no pull request until the
owner asks. Every phase ends with the checks above and the device check. Add a line under `## Unreleased` in
`docs/CHANGELOG.md` when users see a change (the hook regenerates `website/*.html`; commit those files in the same
commit). Update the Phase J rows in `docs/ANDROID_PLAN.md` when a phase changes what they say.

---

### Phase 1: Groundwork (run log, stop reasons, FLOOD_WAIT across processes, Background lab)

**Goal:** record every run and why it ended, keep Telegram's wait across process death, and give the owner a Debug
screen to trigger each job. Every later phase is checked with this.

**1.1 Core (pure Kotlin, unit-tested).** New file
`android/core/src/main/kotlin/app/lelvo/core/backup/BackgroundRuns.kt`, a port of the iOS
`BackgroundRuns.swift` with the same names and rules:

```kotlin
enum class RunSource { App, User, NewPhotos, AutoRun, SafetyNet, Overnight, Refresh }

// core has kotlinx-serialization-json but NOT the compiler plugin (core/build.gradle.kts uses the JSON tree only).
// Encode by hand with JsonObject, the way LibraryItem stores its fields. No @Serializable, no build change.
data class RunRecord(
    val source: RunSource,
    val startedAt: Long,        // epoch ms
    val seconds: Double,
    val uploaded: Int,
    val remaining: Int,
    val stop: String? = null,   // "finished", "out of time", "stopped by Android (reason N)", "paused", blocker text
)

object BackgroundRuns {
    fun appending(r: RunRecord, list: List<RunRecord>, limit: Int = 200): List<RunRecord>
    /** When the next automatic run should start after this one: null = stop the chain. */
    fun nextAutoRun(remaining: Int, stoppedByTime: Boolean, blocked: Boolean, floodUntil: Long, now: Long,
                    gapMs: Long = 15 * 60_000L): Long?
    /** Whether a run may start another item. A user run (deadline null) always may; phase 3.0 uses this. */
    fun mayTakeNextItem(deadline: Long?, now: Long): Boolean
    /** Phase 3.1's counter: a run made progress if an item finished OR a part was saved (big videos resume by part). */
    fun emptyRunsAfter(previous: Int, uploaded: Int, partsSaved: Int, userRun: Boolean): Int
    fun nextReminder(lastUpload: Long?, waiting: Int, remindersSent: Int, now: Long): Long?   // 2, 4, 8, 8 days
    fun isOvernight(epochMs: Long, zone: ZoneId): Boolean                                   // 22:00–07:00
    fun summaryText(photos: Int, videos: Int, overnight: Boolean): String?                  // same words as iOS
}
```

`nextAutoRun` rules: `remaining == 0` → null; `blocked` (paused, no access, waiting for Wi-Fi/power) → null (the
constraints or the next trigger bring it back); otherwise `max(now + gapMs, floodUntil)`. If the run wasn't stopped by
time (it ended with failures only), still `now + gapMs` so retries go on, but the caller stops after 3 chained runs
in a row with no progress (`emptyRunsAfter`, phase 3).

`mayTakeNextItem`: `deadline == null` → true; otherwise `now < deadline`. `emptyRunsAfter`: user run → 0;
`uploaded > 0 || partsSaved > 0` → 0; otherwise `previous + 1`.

Tests: `android/core/src/test/kotlin/app/lelvo/core/backup/BackgroundRunsTest.kt`. Cover the 200 limit, each
`nextAutoRun` case (FLOOD_WAIT later than 15 min wins), reminder backoff 2/4/8/8 and reset, `isOvernight` edges
(21:59, 22:00, 06:59, 07:00), `mayTakeNextItem` (no deadline, before, exactly at, after), `emptyRunsAfter`
(a run that only saved parts of a large video resets the count; user run resets it), and every `summaryText` form ("1 photo", "2 videos", both, zero → null). Copy the iOS
test cases from `BackgroundRunsTests.swift` so both apps agree.

**1.2 Store the runs.** `Prefs`: `runRecords: List<RunRecord>` (JSON string) and `record(r)`. Small, rarely read, not
library data, so not in Room.

**1.3 Record every run.** In `BackupWorker.doWork`, wrap each `kind` so a `RunRecord` is written in a `finally`, with
`stop` set from: the `Summary` (`error`, `remaining`), `isStopped` + `stopReason` (WorkManager 2.9+ `getStopReason()`),
or "paused". One log line per run: `Run (AutoRun): 412 s, uploaded 37, 1,203 waiting, out of time`.
`Summary` gets four fields:
- `uploadedVideos: Int`, for the summary text (count it where `uploaded` is counted);
- `partsSaved: Int`, +1 in the upload `checkpoint` callback each time a part is confirmed and stored;
- `stoppedByTime: Boolean`, set by phase 3.0;
- `blockedByRule: Boolean`, true when the run ended because `blocker()` returned a reason (paused, no photo access,
  waiting for Wi-Fi, waiting for power). Phase 3.1 uses it to stop the chain.

**1.4 FLOOD_WAIT across processes.** In `BackupEngine`, `holdFor()` also writes `pausedUntil` to `Prefs`
(`floodUntil`, epoch ms); the engine reads it back in `init`. `waitForFloodPause()` keeps working as is. Unit-test the
"keep the later of the two" rule if it moves to core. **Why:** WorkManager runs each job in whatever process exists;
after Android ends the process, the memory value is gone and the next job would send during Telegram's wait.

**1.5 Background lab (Debug only).** New `android/app/src/debug/.../BackgroundLabScreen.kt` (or behind
`BuildConfig.DEBUG` in `debug/`, matching `CoreCheckScreen.kt`), reached from Settings in Debug builds:
- "Run new-photos job now", "Run automatic run now", "Run safety net now", "Run overnight now": enqueue the real work
  request with no delay (`OneTimeWorkRequest` with the same `KIND`).
- The last 20 `RunRecord`s (source, time, seconds, uploaded, remaining, stop).
- Current WorkManager state of each unique work (`getWorkInfosForUniqueWorkFlow`): ENQUEUED/RUNNING/BLOCKED, plus
  `nextScheduleTimeMillis` (WorkManager 2.9+).
- Device state: `isIgnoringBatteryOptimizations`, `isBackgroundRestricted`, standby bucket, photo access (phase 6
  uses the same helpers; add them here first, read-only).

**Done when:** tests pass, the build has no new warnings, and on the emulator the lab lists a record after each
button, with a stop reason. Forcing a job with
`adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler app.lelvo.android <jobId>` (job ids from
`adb shell dumpsys jobscheduler | grep -A3 app.lelvo.android`) also adds a record.

---

### Phase 2: A trigger that never misses photos (copied from Immich)

**Goal:** split the listener from the uploader, and arm the next trigger **before** any upload starts.

**2.1** `BackupScheduler.armNewPhotos`: the `NEW_PHOTOS` request keeps both content URI triggers and the
30 s / 3 min delays, and **drops** the network and charging constraints. It does no network work, so it needs none.

**2.2** `BackupWorker`, kind `NEW_PHOTOS` (new `newPhotos()`):
1. Re-arm first: `BackupScheduler.armNewPhotos(ctx, prefs, ExistingWorkPolicy.APPEND_OR_REPLACE)`. A content trigger
   fires once; arming it now means photos taken from here on fire it again. Do not use `REPLACE`. Immich and
   Nextcloud do, and it can cancel the work that is running (Nextcloud says so in a comment on their upload job).
2. If automatic backup is off or paused: record and return. Still re-arm, so turning it back on is not the only
   way the listener exists. `schedule()` is what cancels it when automatic backup is switched off.
3. Queue new photos without TDLib, even when `triggeredContentUris` is empty and even when the phone is saving
   battery: call the engine's MediaStore part only (`enqueueNew()`; make it `internal`/public if needed, and make
   sure it doesn't need Telegram). The trigger is only a signal. Nextcloud skips this when the URI list is empty
   or power saving is on, and files then wait for another scan. Log "Looked for new photos: N queued".
4. If anything is waiting: `BackupScheduler.startAutoRun(ctx, prefs, delayMs = 0)`.
5. Never call `run(...)` here. Remove the `finally` re-arm (step 1 replaces it).

**2.3** New unique work `AUTO_RUN` in `BackupScheduler`:

```kotlin
fun startAutoRun(context: Context, prefs: Prefs, delayMs: Long, policy: ExistingWorkPolicy = ExistingWorkPolicy.KEEP) {
    val network = if (prefs.wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED
    val expedited = delayMs == 0L && !prefs.chargingOnly
    // Expedited work accepts only network and storage constraints; build() throws IllegalArgumentException
    // ("Expedited jobs only support network and storage constraints") for battery-not-low, charging or idle.
    val c = Constraints.Builder()
        .setRequiredNetworkType(network)
        .apply { if (!expedited) setRequiresBatteryNotLow(true) }
        .apply { if (prefs.chargingOnly) setRequiresCharging(true) }
        .build()
    val b = OneTimeWorkRequestBuilder<BackupWorker>()
        .setInputData(workDataOf(BackupWorker.KIND to AUTO_RUN))
        .setConstraints(c)
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
    if (expedited) b.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
    else b.setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
    WorkManager.getInstance(context).enqueueUniqueWork(AUTO_RUN, policy, b.build())
}
```

The expedited request runs once, right after new photos. Every chained run is delayed, so it gets battery-not-low.
Add a JVM or instrumented test that builds both requests (expedited and delayed, with and without "Only while
charging") so a constraint that throws is caught before a device sees it.

`KEEP` is right: a run already queued or running will pick up the new photos itself (the engine queues new photos at
the start of every run). A photo arriving **during** a run is covered by the chain in phase 3.

**2.4** Kind `AUTO_RUN` in the worker: `app.backup.run(userStarted = false, includeNew = false)` (automatic backup on
means the engine queues new photos). Expedited jobs on Android 11 and older need `getForegroundInfo()`; the worker
already has it. Record the run.

**2.5** `cancelAll` and `schedule(...)` include `AUTO_RUN`. When automatic backup is turned off, cancel `NEW_PHOTOS`
and `AUTO_RUN`. `schedule()` stays in `LelvoApp.onCreate` (it is already there): a worker that starts the process
re-arms the trigger. Immich added a 15-second backup on process start for this. Do not move `schedule()` to the
activity.

**Tests:** none in core beyond phase 1. Check there's no test asserting the old trigger constraints.

**Device check (emulator):** push 3 photos with `adb push a.jpg /sdcard/DCIM/Camera/` then
`adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/DCIM/Camera/a.jpg` (or take
them with the emulator camera). Within ~1 minute the lab shows `NewPhotos` then `AutoRun` with uploaded 3. Add a
photo while an `AutoRun` uploads a long backlog: it's in the library by the end of the chain.

**Done when:** every new photo produces a `NewPhotos` record within ~3 minutes, the trigger is always ENQUEUED again
(lab), and Wi-Fi only / charging only hold `AUTO_RUN` but never the trigger.

---

### Phase 3: Finish a backlog without the charger (copied from iOS phase 5, Nextcloud's resumable uploads, and Ente's 9-minute budget)

**Goal:** a large queue keeps going in short runs until it's done, and a missed trigger is caught within an hour.
Each background upload stops itself at 9 minutes, while the process can still book the next run. Waiting for
Android's 10-minute kill is how a chain gets lost: the process is already being torn down.

**3.0 Stop at 9 minutes.** `AUTO_RUN`, `SAFETY_NET` and the upload part of `OVERNIGHT` pass a deadline into
`BackupEngine.run` (9 minutes from the start of `doWork`, constant next to `MAX_CONCURRENT_UPLOADS`). Each lane
asks `BackgroundRuns.mayTakeNextItem(deadline, now)` before it takes an item, so the rule lives in core with tests.
When it says no, the engine takes no new item. Uploads already in flight stop the way a cancel already stops them:
the item goes back to the queue and the part being sent is thrown away. Parts Telegram already confirmed, and the
resume point (`parts`, `uploadResume`, saved through `checkpoint`), are **kept**, so the next run continues a large
video where it stopped instead of starting again. Check this with a test before relying on it. Nothing half-sent
counts as backed up. `run()` then
**returns** a `Summary` with `stoppedByTime = true` and stop text "out of time". It must not throw, or `doWork`
cannot record the run and book the next one. Do not call `pause()` for this: `pause()` sets `backupPaused` and
the chain would stop until the user taps Back up now. Do not apply this deadline to a **user** run: that one is
the foreground `dataSync` service and may run for hours (phase 7). Ente's shipping path misses this: their Dart
timeout is 1 hour, so Android kills the process at 10 minutes and the next periodic slot is whenever Android
feels like it. Their internal plugin does set a 9-minute budget (`kBGTaskMLSelfStopAndroid`). Copy that number.

**3.1 The chain.** At the end of kind `AUTO_RUN` (and `SAFETY_NET`, `NEW_PHOTOS` doesn't upload), including when
3.0 stopped the run:

```kotlin
val next = BackgroundRuns.nextAutoRun(summary.remaining, summary.stoppedByTime, blocked = summary.blockedByRule,
                                      floodUntil = prefs.floodUntil, now = System.currentTimeMillis())
if (next != null && prefs.emptyChainedRuns < 3)
    BackupScheduler.startAutoRun(ctx, prefs, delayMs = next - now, policy = ExistingWorkPolicy.APPEND_OR_REPLACE)
```

`emptyChainedRuns = BackgroundRuns.emptyRunsAfter(prev, summary.uploaded, summary.partsSaved, userRun)`. Count
parts, not only finished items: a 4 GB video can take several 9-minute runs, and counting only `uploaded` would stop
the chain after three runs while the video is a third done. **Why 15 minutes:**
Android 16 counts job runtime against a quota; a gap keeps Lelvo inside it and lets the phone rest. Short runs back
to back would hit the quota and Android would hold the app back more.

Do not chain when Lelvo is on screen or a `USER` work is ENQUEUED or RUNNING. Phase 4's user run continues the
queue then, with the progress notification and without the 9-minute cap. Chaining as well would start a second
backup the moment the user run is waiting for this one to finish.

If Android stops the worker first (`isStopped`), `doWork` still reaches the `finally` briefly: book the next run
there, quickly (no network), before rethrowing the `CancellationException`. That path is the fallback. The normal
path is 3.0, which returns on its own.

**3.2 Safety net.** New periodic unique work `SAFETY_NET`, every 60 min (flex 15), constraints: network rule,
battery not low, charging if chosen. **Do not** set `requiresDeviceIdle`. Ente's older processing job required idle
and charging together, so it rarely ran. Enqueue with `ExistingPeriodicWorkPolicy.UPDATE` every time `schedule()`
runs, including when Wi-Fi only or charging only changes, so the request is replaced rather than left with the old
constraints (`KEEP` on a periodic job is how Nextcloud and Ente's early setup kept a stale request). Body: if
automatic backup is on and `readyCount() > 0` and `AUTO_RUN` is not ENQUEUED/RUNNING, run `app.backup.run(...)` like
`AUTO_RUN` (same 9-minute deadline) and chain as in 3.1. It catches photos whose trigger was lost (reboot, an OEM
kill, WorkManager rescheduling after force stop). It only uploads when something waits.

**3.3 Overnight.** Keep `OVERNIGHT` on the charger (it also reads photos for search, which isn't worth battery). Its
upload uses the same 9-minute deadline. If the queue is empty before the deadline, index for search as it does
today. If the deadline hits during the upload, skip indexing this time and let the phase 3 chain finish the queue.
**Don't** remove `setRequiresCharging(true)` from it: the chain and the safety net cover battery. Enqueue it with
`UPDATE` when backup settings change, same as the safety net (today `schedule()` uses `KEEP` unless `rulesChanged`).

**3.4 Refresh.** Unchanged (index catch-up every 4 h).

**Device check:** queue 300+ photos (push a folder, or choose an older date range in Backup options) with Lelvo closed
and the emulator on battery (`adb shell dumpsys battery unplug`). Over the next hour the lab shows several `AutoRun`
records about 15 min apart, each about 9 min with stop "out of time", until `remaining` is 0. A run the lab shows
near 10 minutes, or one with a WorkManager stop reason and no following `AutoRun`, means 3.0 did not fire. Then
`adb shell dumpsys battery reset`. With "Only while charging" on: nothing runs unplugged, and runs start when
plugged in (`adb shell dumpsys battery set ac 1`).

**Done when:** a backlog finishes on battery with Lelvo closed, the chain stops at 0 waiting, after 3 empty runs, and
while paused; and `FLOOD_WAIT` pushes the next run past Telegram's wait (simulate with a Debug lab button that sets
`floodUntil` to now + 20 min).

---

### Phase 4: Back up when Lelvo opens (copied from iOS `AutoStart`)

**Goal:** opening Lelvo with photos waiting starts a backup at once, shown in the progress notification, which keeps
going after leaving.

**4.1** New `object AutoStart` in `background/`, called from `LelvoApp` when the app comes to the front (the activity
lifecycle callback that sets `isOnScreen = true`; use `ProcessLifecycleOwner` only if it's already a dependency):
- return if automatic backup is off, paused, demo mode, a `USER` work is ENQUEUED/RUNNING, or the last auto-start
  was under 5 minutes ago (a `@Volatile` field, not Prefs);
- return if `app.backup.blocker() != null` and the engine is not already running;
- if the engine is running (an `AUTO_RUN` in this same process): log "Auto-start on open: backup already running",
  remember the time and `startNow(includeNew = false)`. Do not call `run()` again and do not cancel `AUTO_RUN`.
  `userRun()` already waits on `activity`, shows the progress notification for the run in progress, then continues
  whatever is left with no 9-minute cap. Phase 3.1 does not chain while that user work is queued. Ente kills its
  background engine on open because a second Flutter engine would upload the same file. Lelvo has one engine, so
  cancelling would only throw away the upload in flight.
- otherwise, on `Dispatchers.IO`: `enqueueNew()`, then `readyCount()`; if 0, log "Auto-start on open: nothing new"
  and return **without** starting the 5 minutes (iOS fix in #125);
- else log "Auto-start on open: N waiting", remember the time and `BackupScheduler.startNow(ctx, includeNew = false)`.
  A user run may start its foreground service because the app is on screen. The 9-minute deadline does not apply
  (phase 3.0).

**4.2** The user run is recorded as `RunSource.App` when AutoStart started it, `User` when a person tapped (pass a
flag in the input data).

**4.3** Don't show "Backup finished" when Lelvo is on screen (already the rule).

**Device check:** add 3 photos with Lelvo closed, open it: the progress notification appears without a tap, the lab
shows an `App` record. Open and close quickly 3 times: one start at most. Open with nothing new: nothing starts.

**Immich's open bug (#31042), checked here:** start a backup that includes a video over 1 GB, press Home, turn the
screen off, wait 15 minutes. The upload must keep going (the progress notification moves, and the log shows parts
being confirmed), and it must not start the video again. Then swipe Lelvo from Recents: the next run continues from the
last confirmed part (the lab shows `partsSaved > 0` on the following run).

**Done when:** as the device check, and the `USER` and `AUTO_RUN` works never upload at the same time (the engine log
shows one "Backup run" at a time).

---

### Phase 5: Turn it on where people already are (copied from iOS phase 2)

**Goal:** new users leave onboarding with automatic backup on (visible, can be turned off); existing users with it off
are asked once.

**Owner sign-off needed before building:** this changes what new users get by default. Confirm the copy and the
default in the PR description.

**5.1** `FirstBackupScreen.kt`: under "Your first photo is safe." (when `finished` or `returning`), a card with a
Material `Switch`, title "Back up new photos automatically", caption "Soon after you take them, and when you open
Lelvo." Starts **on**. On "Start using Lelvo": write `prefs.autoBackup`, set new `prefs.autoBackupAsked = true`, call
`BackupScheduler.schedule(ctx, prefs)`. Below the button: "You can change this in Settings." When on, change the
detail to "Backed up and checked, at full quality." (drop "Back up now sends the rest.").

**5.2** `BackupScreen.kt`: a card at the top when `!prefs.autoBackup && !prefs.autoBackupAsked`: title "Back up new
photos automatically", body "Lelvo can back up new photos soon after you take them.", buttons **Turn on** (sets both,
schedules, starts `startNow(includeNew = true)`, snackbar "Automatic backup is on") and **Not now** (sets
`autoBackupAsked` only; the card never comes back).

**5.3** `Prefs`: add `autoBackupAsked` (default `false`). **Don't change `autoBackup`'s default.**

**5.4** Settings footer under the switch: on → "Lelvo backs up soon after you take photos, and when you open it.";
off → keep today's text.

**5.5** Notification permission (Android 13+) is already asked for user runs; don't ask again here.

**Device check:** screenshots of the onboarding card and the Backup tab card, light and dark (owner rule: Google
Photos look, `docs/DESIGN.md` colours). On a fresh test account in the emulator's second user only if the owner says
so; otherwise preview the screen with Compose `@Preview`.

**Done when:** new installs finish onboarding with automatic backup on; the card shows once and never after an answer.

---

### Phase 6: Say when Android blocks the backup, with a Fix button (copied from Immich and Nextcloud; Ente never built this)

**Goal:** the Backup tab and Settings tell the truth about whether background backup can run on this phone. Ente's
help page is the only place they say "set battery to Unrestricted", and their own reports show that is not enough:
people never find the screen, and some phones still drop the job after they do. The card is the part Ente skipped.

**6.1 Core rule** in `BackgroundRuns.kt`, unit-tested:

```kotlin
enum class BackgroundIssue { PartialPhotoAccess, BackgroundRestricted, BatteryOptimized, RareBucket, ForceStopped, None }
fun backgroundIssue(partialAccess: Boolean, restricted: Boolean, optimized: Boolean, bucket: Int,
                    lastExitForceStop: Boolean, lastAutoUpload: Long?, waiting: Int, now: Long): BackgroundIssue
```

Order (first match wins): `PartialPhotoAccess` (new photos are invisible to Lelvo) → `BackgroundRestricted` (Android
won't run jobs at all) → `ForceStopped` (last exit was a force stop and no automatic run has happened since) →
`RareBucket` / `BatteryOptimized` only when photos have waited **more than 24 h** with no automatic upload (many
phones work fine optimised; don't nag those).

**6.2 Reading the state** (app module, `background/DeviceState.kt`, all API ≥ 29 unless noted, no new permissions):
- photo access: the existing `photos.status()` (`Partial` = "Selected photos only");
- `ActivityManager.isBackgroundRestricted()` (API 28+);
- `PowerManager.isIgnoringBatteryOptimizations(packageName)`;
- `UsageStatsManager.getAppStandbyBucket()` (own app, no permission; `RESTRICTED` or `RARE` count);
- force stop: `ActivityManager.getHistoricalProcessExitReasons(packageName, 0, 1)` → `REASON_USER_REQUESTED`
  (API 30+; on 29 assume false).

**6.3 UI.**
- Backup tab, top card when the issue isn't `None` (one at a time, after phase 5's card):
  - PartialPhotoAccess: "Lelvo can only see the photos you selected. New photos aren't backed up." **[Allow all photos]**
    → the app's settings page (`Settings.ACTION_APPLICATION_DETAILS_SETTINGS`).
  - BackgroundRestricted: "Android stopped Lelvo from running in the background, so new photos wait until you open
    it." **[Fix]** → app details settings.
  - BatteryOptimized / RareBucket: "Photos have waited since yesterday. Your phone may be saving battery by stopping
    Lelvo." **[Fix]** → app battery settings (`ACTION_APPLICATION_DETAILS_SETTINGS`; on Android 12+ the Battery row
    there has "Unrestricted"). A second line by maker, from `Build.MANUFACTURER`: Samsung "Also remove Lelvo from
    Sleeping apps in Battery settings."; Xiaomi/Redmi/POCO "Also turn on Autostart for Lelvo."; others none. Link
    "More help" to `https://dontkillmyapp.com/<maker>` (an outside page; plain link, no tracking).
  - ForceStopped: "Automatic backup stops when Lelvo is force-stopped. It started again now that Lelvo is open." (info
    only, dismissible, shown once per force stop).
- Settings → Backup: row "Background backup" with value "Working" / "Limited" / "Off", opening a small screen with
  the same lines and the last automatic run ("Last automatic backup: today, 14:20").
- Use Material 3 cards and the Lelvo colours; light and dark checked (owner rule).

**6.4** Never request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; open settings screens only.

**Device check:** emulator: `adb shell cmd appops set app.lelvo.android RUN_ANY_IN_BACKGROUND ignore` →
BackgroundRestricted card (undo with `allow`). `adb shell am set-standby-bucket app.lelvo.android rare` → after the
24 h rule (Debug lab button "pretend photos waited a day") the battery card. `adb shell am force-stop app.lelvo.android`,
open → ForceStopped note once. Partial access: Android settings → Lelvo → Photos → "Allow limited access".

**Done when:** each state shows the right card and Fix lands on the right settings screen; a healthy phone shows no card.

---

### Phase 7: Long user runs that Android stops

**Goal:** a big backup the user started survives Android's limits and says what happens next.

**7.1 6-hour `dataSync` limit (Android 15+).** This applies only to a user run. Background runs already stop at
9 minutes (phase 3.0), which is how Ente stays clear of the quota; they never handle the timeout because they have
no long foreground backup. WorkManager stops the worker with a stop reason when the foreground service times out
(verify the reason constant in WorkManager 2.11 / `WorkInfo.STOP_REASON_FOREGROUND_SERVICE_TIMEOUT`).
In `userRun()`, when stopped for that reason: record it, show "Backup paused. Android limits long backups to 6 hours a
day. It continues in the background." and start the phase 3 chain (`startAutoRun(delay 15 min)`) so the rest goes in
short jobs. Test with `adb shell am compat enable FGS_INTRODUCE_TIME_LIMITS app.lelvo.android` and
`adb shell device_config put activity_manager data_sync_fgs_timeout_duration 60000` (1 minute; reset afterwards with
`device_config delete`).

**7.2 Foreground refused** (already handled: runs as a normal job). Add the chain there too, so it continues after
10 minutes.

**7.3 Android 16 quotas.** Jobs started while Lelvo is on screen and still running after it leaves now count against
the quota. No code beyond the chain; note in the PR how many runs the backlog test needed on Android 16.

**Done when:** a timed-out user run hands over to the chain and the notification says so.

---

### Phase 8: Morning summary and stuck reminder (copied from iOS phase 9)

**Goal:** a quiet summary of what went up overnight, and a reminder when backup has been stuck for days. Off until the
user turns it on.

**8.1** Settings → Backup options: "Backup notifications" switch (off by default). Turning it on asks
`POST_NOTIFICATIONS` on Android 13+ if not granted; if denied: "Turn on notifications for Lelvo in Settings." with a
button to the app's notification settings.

**8.2** A separate low-importance channel "Backup summaries" (so people can mute it without muting progress).

**8.3 Summary.** After an `AutoRun`/`SafetyNet`/`Overnight` run that uploaded during the night (`isOvernight`), add to
the night's totals in Prefs and (re)book one notification for 07:30 with a `OneTimeWorkRequest` (`SUMMARY`, initial
delay to 07:30, `REPLACE`). Text from `summaryText`. Fixed notification id, so it replaces.

**8.4 Reminder.** When Lelvo goes to the background and after each automatic run: compute `nextReminder`; book a
`REMINDER` one-time work for that time (`REPLACE`; none when nothing waits). The worker re-checks the count before
posting "Backup waiting" / "N items are waiting to be backed up. Open Lelvo to continue." Reset after any upload.
WorkManager may be late in Doze; fine for a reminder. No exact alarms.

**8.5** Tapping either opens the Backup tab. Counts only: no names, places or library names.

**Done when:** each appears at most once at a time, only when turned on, and opens the Backup tab.

---

### Phase 9: Words, real-phone test, release

**9.1 Docs:** `docs/ANDROID_PLAN.md` Phase J rows; `docs/ARCHITECTURE.md` Android background section if it has one;
`docs/FAQ.md` under "Backing up": "Why did backup stop on my Android phone?" (battery setting, force stop, selected
photos, Samsung and Xiaomi lines); `docs/CHANGELOG.md` `## Unreleased`.

**9.2 Test matrix** (write the results in the PR; say what wasn't tested):

| Device | Android | Must pass |
|---|---|---|
| Pixel_9 emulator | 16 | every phase's device check |
| A Pixel or near-stock phone, if available | 14–16 | 24 h with Lelvo closed: new photos reach the library through `NewPhotos`/`AutoRun` (count them from the lab) |
| A Samsung phone, if available | 14+ | same, with default battery settings, then after the Fix steps |
| A Xiaomi/Redmi phone, if available | 13+ | same; expect the battery card before the Fix |

Each real phone also: reboot with photos waiting (safety net picks them up after unlock), force stop (note shown,
backup resumes after opening), Wi-Fi only on mobile data (nothing uploads, log shows the constraint), Paused (nothing
uploads), and battery use for a normal day from Settings → Battery (if Lelvo is over a few percent, raise the chain gap
to 30 min).

**9.3 Release:** follow `docs/RELEASING.md`.

**Done when:** the matrix rows that could be tested pass, docs match the app, and the owner approves.

---

## Testing commands (emulator)

```sh
adb shell dumpsys jobscheduler | grep -B2 -A12 app.lelvo.android        # what's scheduled and why it waits
adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler app.lelvo.android <jobId>   # force a job
adb shell dumpsys deviceidle force-idle                                  # Doze; `unforce` to undo
adb shell am set-standby-bucket app.lelvo.android rare                   # `active` to undo
adb shell cmd appops set app.lelvo.android RUN_ANY_IN_BACKGROUND ignore  # `allow` to undo
adb shell dumpsys battery unplug                                         # `reset` to undo
adb logcat -s WM-WorkerWrapper WM-SystemJobScheduler JobScheduler
```

`am kill` and `am force-stop` both look like a force stop to WorkManager, which drops pending triggers until the app
opens (seen in Phase J). Use the lab buttons and `cmd jobscheduler run -f` instead to simulate background runs.

---

## Not doing (and why)

- **`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` dialog:** Google Play restricts it; the settings screen does the same job.
- **A foreground service that keeps running to watch for photos:** Android 12+ blocks starting it from the background,
  Android 15 limits `dataSync` to 6 h a day, and it's a permanent notification. Nextcloud removed theirs.
- **User-initiated data transfer jobs (Android 14+):** the right API for very long user runs, but there's no
  WorkManager support yet and it needs a second scheduler. Revisit if phase 7's 6-hour handover isn't enough.
- **Exact alarms or a server push:** no server by design, and exact alarms need a restricted permission.
- **Uploading in `NEW_PHOTOS` itself:** keeps the listener cheap and unconstrained (the Immich lesson).
- **Changing the storage format:** nothing here touches captions, encryption or the header.

## Sources

- Android: [Foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout),
  [Android 16 behaviour changes (job quotas)](https://developer.android.com/about/versions/16/behavior-changes-all),
  [Power management limits](https://developer.android.com/topic/performance/power/power-details),
  [User-initiated data transfer](https://developer.android.com/develop/background-work/background-tasks/uidt),
  [FGS troubleshooting](https://developer.android.com/develop/background-work/services/fgs/troubleshooting),
  [Using WorkManager on Android 12](https://medium.com/androiddevelopers/using-workmanager-on-android-12-f7d483ca0ecb)
- Immich: [listener/worker split commit](https://ark.sudovanilla.org/Infrastructure/immich/commit/4fe535e5e88cda4e7f3ed5c07f0ffc37e8623165),
  [Automatic backup docs](https://docs.immich.app/features/automatic-backup),
  [Android 15 background issue](https://github.com/immich-app/immich/issues/26115),
  [periodic worker PR #23563](https://github.com/immich-app/immich/pull/23563),
  [backup only in foreground #31042](https://github.com/immich-app/immich/issues/31042)
- Nextcloud: [resumable auto upload issue #12954](https://www.github.com/nextcloud/android/issues/12954),
  [flaky auto upload #12879](https://www.github.com/nextcloud/android/issues/12879)
- Ente code (main, 2026-11-14): `mobile/apps/photos/lib/utils/bg_task_utils.dart` (the scheduler users get),
  `mobile/apps/photos/lib/utils/background_tasks.dart` and `plugins/ente_background_manager` (internal users only;
  9-minute budget, `UPDATE` policy), `lib/services/sync/local_sync_service.dart` (in-process photo callback),
  `lib/main.dart` (`kBGTaskMLSelfStopAndroid` = 9 min, foreground sync every 5 min). Help pages, which lag the code:
  [Background sync](https://help.ente.io/photos/features/background),
  [Backup and sync FAQ](https://help.ente.io/photos/faq/backup-and-sync). Open reports that it still fails on a
  stock Pixel: [ente-io/ente#5988](https://github.com/ente-io/ente/issues/5988),
  [ente-io/ente#4996](https://github.com/ente-io/ente/issues/4996)
- Maker restrictions: [dontkillmyapp.com](https://dontkillmyapp.com),
  [flutter_workmanager troubleshooting](https://docs.page/fluttercommunity/flutter_workmanager/troubleshooting)
