# Automatic backup on iPhone: design and build plan

Status: draft for the owner's approval, 2026-11-14. Issue: #122.

This is the reference for the whole feature until it works on the owner's iPhone. It's written so another model or
contributor can build it phase by phase without guessing. Read the whole of "Before you start" first, then do **one
phase at a time, in order**. Each phase lists the files, the exact change, the tests, the device check and when it's
done. Don't start a phase before the previous one is done and checked on the iPhone.

---

## Before you start (read this, every session)

1. Read `AGENTS.md` (the non-negotiables) and `CLAUDE.md` (build commands, gotchas). This plan never overrides them.
2. Read `docs/ARCHITECTURE.md`, section "Platform specifics" and the "Background reality on iOS" paragraph after it.
3. Read these files before you touch them (they're referenced in every phase):
   - `Shared/Services/BackgroundTasks.swift`: BGTask registration, scheduling, `ContinuedBackup`
   - `Shared/Services/BackupEngine.swift`: `run(...)` (around line 474), `blocker()` (around line 286),
     `enqueueNewAssets` (around line 301), `runnableItems` (around line 465). It's 1,000+ lines: grep for the
     symbol and read only that range.
   - `Packages/LelvoCore/Sources/LelvoCore/Backup/UploadOrder.swift`: the order items are uploaded in
   - `iOS/Intents/BackupIntents.swift`: the Shortcuts actions
   - `iOS/App/LelvoApp.swift`: `AppDelegate` and the `scenePhase` handler
   - `Shared/Services/Preferences.swift`: `Prefs` keys and defaults
   - `Shared/Views/Onboarding/IntroView.swift`: `FirstBackupView` (around line 837), the last onboarding screen
   - `Shared/Views/Backup/BackupDashboardView.swift`: the Backup tab
   - `Shared/Views/Settings/SettingsView.swift`: the Backup section (around line 55)
4. Work on the branch for this plan (`ios/automatic-backup`) or a fresh branch from `main` per phase. Stage files by
   path, never `git add -A` (other sessions edit the tree at the same time). Never commit `.cursor/` or `marketing/`.
5. Check after every phase (all three must pass):
   ```sh
   Scripts/build.sh test
   Scripts/build.sh ios > build/ios.log 2>&1; tail -5 build/ios.log; Scripts/check-warnings.sh build/ios.log
   Scripts/build.sh mac > build/mac.log 2>&1; tail -5 build/mac.log; Scripts/check-warnings.sh build/mac.log
   ```
   Never print a whole `xcodebuild` log. Most of this feature is iOS-only: wrap it in `#if os(iOS)` (and
   `!targetEnvironment(macCatalyst)` where `BackgroundTasks.swift` already does), so the Mac still builds.
6. Then test on the owner's iPhone exactly as described in "Testing on the owner's iPhone" below.

### Rules that matter most here

- **Never lose a photo.** Background runs use the same engine, so an item is only backed up when Telegram has
  confirmed every part at the expected size. A run that iOS stops half-way leaves the item queued, never "done".
- **Respect Telegram.** At most two parallel uploads (`BackupEngine.maxConcurrentUploads`), honour `FLOOD_WAIT`. More
  background runs must not mean more parallel uploads. The engine's `running` gate already stops two runs at once;
  keep using `engine.run(...)` and never upload outside it.
- **Respect the user's settings** in every background path: "Back up new photos automatically" (`Prefs.autoBackup`),
  "Paused" (`Prefs.backupPaused`), "Wi-Fi only" (`Prefs.wifiOnly`), "Only while charging" (`Prefs.chargingOnly`).
  `engine.run` already checks pause and `blocker()`; don't bypass them.
- **No secrets in logs.** Log through `appLog(...)` / `AppLog.shared.warn(...)`. Never log file ids, phone numbers or
  photo names.
- **Nothing heavy on the main thread.** PhotoKit fetches and SQLite run in `Task.detached` or the engine.
- **No new dependencies, no server.**
- **User-facing words:** short sentences, plain words, no jargon, no exclamation marks. Say "your Telegram library".
  Use the exact copy in this plan unless the owner changes it.

---

## Why this exists

People expect Google Photos' switch, "Back up photos and videos on this device automatically": photos go up without
opening the app. On iPhone Lelvo today:

- "Back up new photos automatically" is **off by default** (`Prefs.autoBackup` is `false` in `Preferences.swift`), and
  onboarding never asks. Most people never get automatic backup at all.
- The background refresh task runs every 4 hours and **never uploads** (it only syncs the index).
- The background processing task only runs on the charger, even when the user didn't choose "Only while charging".
- Opening the app doesn't start a backup by itself.

### Why we can't simply copy Google

| | Google Photos | Lelvo |
|---|---|---|
| Encryption | Google holds the keys. Not end-to-end. | End-to-end. Only your devices have the key. |
| Where photos go | Google's own HTTPS servers | Your Telegram account, through TDLib (MTProto) |
| iOS background uploads (`URLSession`) | Work: plain HTTPS | Can't be used: TDLib's MTProto connections are cut when iOS suspends the app |
| Apple's photo backup extension (iOS 26.1, `PHBackgroundResourceUploadExtension`) | Fits: iOS uploads the original file to a fixed HTTPS server | Can't be used: iOS sends the photo **unencrypted**, and the app never gets to encrypt it first |
| Silent push from a server | Possible | We have no server, by design |

Apple gives end-to-end apps no API for "upload in the background whenever there's something new". So we do what the
best end-to-end apps do, plus one thing they don't.

### What the best end-to-end apps do (checked in their code, 2026-11-14)

- **Ente Photos** (end-to-end, open source, `ente-io/ente`): background refresh about every 15 min that uploads,
  background processing about every hour, and a **silent push from their server every 60 min**
  (`server/pkg/controller/push.go`, `pushIntervalInMinutes = 60`, `content-available: 1`, `apns-priority: 5`). Photos
  only in the background; videos wait for the app.
- **Proton Drive** (end-to-end, open source, `ProtonDriveApps/ios-drive`): one background processing task **without**
  needing the charger (`requiresExternalPower = false`, `requiresNetworkConnectivity = true`), rescheduled straight
  away while work is left and once a day when it isn't (`BackgroundPhotoUploadContainer.swift`). Local notifications:
  "photos uploaded" after a background run, and a reminder to open the app when the backup is stuck, backing off
  2, 4, 8 days (`BackgroundAppRefreshTaskScheduler.swift`). No server push.
- **Neither has Shortcuts automations.** That's our addition.

### What the user gets

**Level 1, for everyone, with no setup** (phases 2–5, 9):
- Automatic backup is **on** after onboarding (they see it and can turn it off).
- Opening Lelvo starts backing up new photos at once, and it keeps going after they leave, with the iPhone's own
  progress indicator (iOS 26).
- A few times a day iOS gives Lelvo short background runs, and new photos go up then.
- Overnight, it backs up everything still waiting, videos included.
- In the morning, a quiet notification: "312 photos and 4 videos backed up overnight" (if notifications are allowed).
- If the backup is stuck for days, a gentle reminder to open Lelvo, never more than once every few days.

**Level 2, optional, about one minute of setup** (phases 6–8):
- A "Camera closed" automation in the Shortcuts app: new photos are backed up within about a minute of taking them.
  Better than Ente's hourly ping, with no server.
- Lelvo offers it at the right moment, explains why it's needed in plain words, guides every tap, and then shows
  "✓ Working", or "Seems off" with a Fix button.

**What we don't promise:** "always, instantly, like Google". The words in the app say what really happens.

---

## Design principles (UI and UX)

1. **Users don't go to Settings.** Everything important is asked or offered where they already are: the last
   onboarding screen, the Backup tab, and a notification. Settings has the same controls for people who look.
2. **Ask at the moment it makes sense.** Automatic backup is asked right after their first photo is safe (they've just
   seen it work). The automation is offered after their first full backup finishes (they trust it now), never during
   sign-up.
3. **Explain the why once, in human words**, never as an error. "We're end-to-end, so iPhone needs your help" makes
   it feel like a privacy feature, not a limitation.
4. **Show, don't tell.** The guide shows each tap with a picture of the real Shortcuts screen, one step at a time.
5. **Close the loop.** After setup, Lelvo confirms it's working, and notices when it stops.
6. **Never nag.** "Not now" hides the offer for 21 days, and after three "Not now"s it isn't offered again (the
   Settings row stays).
7. **Look like Apple's own apps** (`docs/DESIGN.md`): grouped lists, system controls, SF Symbols, Dynamic Type,
   VoiceOver labels, light and dark mode. The accent colour only marks what you can act on.

---

## Screens and exact words

Mockups are for layout only. Build them with standard SwiftUI (`List`, `Section`, `Toggle`, `Button`, `Label`).

### A. Last onboarding screen (`FirstBackupView`), after "Your first photo is safe."

```
┌─────────────────────────────────────┐
│          [photo, checkmark]          │
│      Your first photo is safe.       │
│  Backed up and checked, at full      │
│  quality.                            │
│                                      │
│ ┌──────────────────────────────────┐ │
│ │ Back up new photos         [ON]  │ │
│ │ automatically                    │ │
│ │ When you open Lelvo, in the      │ │
│ │ background, and overnight.       │ │
│ └──────────────────────────────────┘ │
│                                      │
│        [ Start using Lelvo ]         │
│  You can change this in Settings.    │
└─────────────────────────────────────┘
```

- The toggle starts **on**. It writes `Prefs.Key.autoBackup` when the user taps "Start using Lelvo".
- Shown only when the first photo is `.safe` or `.alreadySafe`, and on the returning-user screen (`returning`).
- VoiceOver: the toggle reads "Back up new photos automatically, on".

### B. Backup tab card for existing users with automatic backup off

Shown at the top of the Backup tab when `Prefs.autoBackup == false` and the user never answered this card.

```
┌──────────────────────────────────────┐
│ ⟳  Back up new photos automatically │
│ Lelvo can back up new photos when    │
│ you open it, in the background and   │
│ overnight.                           │
│ [ Turn on ]              [ Not now ] │
└──────────────────────────────────────┘
```

"Not now" records the answer and the card never comes back (the Settings toggle stays).

### C. Offer card for the automation (Backup tab), after the first full backup

```
┌──────────────────────────────────────┐
│ ⚡ Back up new photos within a minute │
│ Set up a Camera automation once.     │
│ It takes about a minute.             │
│ [ Show me how ]          [ Not now ] │
└──────────────────────────────────────┘
```

### D. "How automatic backup works on iPhone" (explainer, pushed from C or from Settings)

Title: **Automatic backup on iPhone**

Section 1, header "What Lelvo does on its own":
- `iphone` "When you open Lelvo": "New photos start backing up at once and keep going after you leave."
- `moon.zzz` "Overnight": "Everything still waiting is backed up while your iPhone rests, videos included."
- `clock.arrow.circlepath` "Now and then": "iPhone gives Lelvo short moments in the background. New photos go up then."

Section 2, header "Why iPhone needs your help":
- Body: "Your photos are end-to-end encrypted before they leave this iPhone, so only your devices can see them. iPhone
  only lets apps upload in the background when the photo goes to the app maker's own server unencrypted. Google
  Photos can do that because Google can see your photos. Lelvo can't, and won't."
- Body: "So Lelvo uses a Shortcuts automation instead: when you close Camera, your iPhone wakes Lelvo for a moment to
  back up what you just took."

Section 3, header "Faster backup (optional)":
- Row: "Back up new photos within a minute" → opens screen E.
- Footer: "About one minute, once. You can remove it any time in the Shortcuts app."

### E. Guided setup: "Back up new photos within a minute"

A paged screen (`TabView` with `.page` style, or a `List` of numbered steps; build the HTML preview first, see
phase 7). Each step has a picture of the real Shortcuts screen (light and dark), one sentence and the exact words to
tap in **bold**.

1. "Open the **Shortcuts** app and tap **Automation** at the bottom."
2. "Tap **+** (or **New Automation**)."
3. "Scroll down and tap **App**."
4. "Tap **Choose**, pick **Camera**, then tap **Done**."
5. "Untick **Is Opened**, tick **Is Closed**."
6. "Choose **Run Immediately**, and turn off **Notify When Run**. Tap **Next**."
7. "Search for **Lelvo**, tap **Back Up New Photos**, then tap **Done**."

Bottom of every step: **[ Open Shortcuts ]** (opens the `shortcuts://` URL) and **Next / Back**.
Last step: **[ I've set it up ]**, then screen F.

Footer on the last step: "If you have Camera in another automation already, add Back Up New Photos to it instead."

### F. "Take a photo to check"

"Take a photo with Camera, close Camera, then come back here." While waiting: a spinner and "Waiting for the
automation…". When the first automation run is recorded (phase 6): a green checkmark, **"It works. New photos now
back up within about a minute."** and **[ Done ]**. After 3 minutes with nothing: "Nothing yet. Check that the
automation says **Is Closed** and **Run Immediately**." with **[ Show the steps again ]**.

### G. Settings → Backup section

```
Back up new photos automatically        [ON]
Faster backup                 Set up ›      ← or "Working ✓" / "Seems off ⚠︎"
Backup options                 …     ›
footer: "Lelvo backs up when you open it, in short background moments and overnight. Faster backup sends new photos
within about a minute."
```

"Faster backup" pushes screen D. When it "Seems off" (phase 8), the row shows `exclamationmark.triangle` in orange
and screen D starts with: "Your automation hasn't run for a while. It may have been turned off." **[ Fix ]** → E.

### H. Notifications (phase 9; only if the user allowed them)

- Morning summary after a background run that uploaded something: title "Backup finished", body "312 photos and
  4 videos backed up overnight." Grouped under one thread so they never pile up.
- Stuck reminder: title "Backup waiting", body "42 photos are waiting to be backed up. Open Lelvo to continue."
  At most after 2 days, then 4, then 8 days; reset after any successful run.

---

## Phases

Each phase is one pull request (the owner merges one before the next starts, per the "sequential PRs" rule), unless
the owner says to group them. Every phase ends with the checks in "Before you start" step 5, the device test, and an
entry under `## Unreleased` in `docs/CHANGELOG.md` (user-facing words). `docs/CHANGELOG.md` changes regenerate
`website/*.html` through a hook (`python3 Scripts/website-pages.py`); commit the regenerated files in the same commit.

---

### Phase 1: Groundwork (run log, health, debug tools)

**Goal:** record every backup run with where it came from, so later phases can show "Working ✓", plan reminders,
and so the owner can prove from the log what happened overnight.

**1.1 Core logic in LelvoCore** (pure Swift, unit-tested, no UIKit):
New file `Packages/LelvoCore/Sources/LelvoCore/Backup/BackgroundRuns.swift`:

```swift
public enum RunSource: String, Codable, Sendable { case app, continued, refresh, processing, shortcut }

public struct RunRecord: Codable, Equatable, Sendable {
    public var source: RunSource
    public var startedAt: Date
    public var seconds: Double
    public var uploaded: Int        // items confirmed by Telegram in this run
    public var remaining: Int       // items still waiting when it ended
}

/// What Settings shows for the Camera automation.
public enum AutomationHealth: Equatable, Sendable { case notSetUp, working(lastRun: Date), seemsOff(lastRun: Date) }

public enum BackgroundRuns {
    /// Keeps the newest `limit` records (default 200).
    public static func appending(_ r: RunRecord, to list: [RunRecord], limit: Int = 200) -> [RunRecord]
    /// notSetUp: no `.shortcut` run ever. working: last shortcut run within `staleAfter` (default 7 days) OR no new
    /// photo was taken since it (`newestPhotoDate <= lastRun`). seemsOff: otherwise.
    public static func automationHealth(_ list: [RunRecord], newestPhotoDate: Date?, now: Date,
                                        staleAfter: TimeInterval = 7 * 86_400) -> AutomationHealth
    /// Proton-style stuck reminder: nil if nothing is waiting or the last successful upload is recent. Otherwise the
    /// date the next reminder may fire: 2 days after the last upload, then 4, then 8 (and 8 after that).
    /// `remindersSent` resets to 0 after any run with uploaded > 0.
    public static func nextReminder(lastUpload: Date?, waiting: Int, remindersSent: Int, now: Date) -> Date?
    /// Summary for a run that uploaded something: "312 photos and 4 videos backed up overnight." Nil if 0.
    public static func summaryText(photos: Int, videos: Int, overnight: Bool) -> String?
}
```

Tests: new `Packages/LelvoCore/Tests/LelvoCoreTests/BackgroundRunsTests.swift` (Swift Testing, `@Test`, like
`LibraryNamesTests.swift`). Cover: the limit; each health state including "no photo taken since the last run counts as
working"; the reminder backoff 2/4/8/8 and the reset; singular and plural text ("1 photo", "1 video", photos only,
videos only, both, zero → nil).

**1.2 Storage in the app.** Keep the list as JSON in `UserDefaults` under a new key in `Prefs.Key`
(`backgroundRuns`), with `Prefs` helpers `Prefs.runRecords` (get) and `Prefs.record(_ r: RunRecord)` (append through
`BackgroundRuns.appending`). Small (200 records), and read rarely. Don't put it in SQLite: it isn't library data.

**1.3 Record runs.** `engine.run(...)` returns a `Summary` (`struct Summary` around line 118 of
`BackupEngine.swift`: `uploaded`, `alreadyBackedUp`, `failed`, `remaining`, `error`, `text`). Record a `RunRecord`
after every run at these call sites, with the right `source`:
- `ContinuedBackup.handle` → `.continued`; `ContinuedBackup.runInForeground` → `.app`
- `BackgroundTasks.handleProcessing` → `.processing`; `handleRefresh` (phase 4) → `.refresh`
- `BackUpNewPhotosIntent.perform` → `.shortcut`
For phase 9's "photos and videos" text, `Summary` also needs `uploadedVideos` (count of uploaded items with
`kind == .video`). Add it next to `uploaded` and count it where `uploaded` is counted.

**1.4 Log lines** (one line per run, no names or ids):
`appLog("Run (refresh): 12 s, uploaded 3, 41 waiting")`. The owner reads these from the phone.

**1.5 Debug tools** (`#if DEBUG` only; never in Release):
A "Background lab" section at the bottom of `SettingsView` (iOS only) with:
- "Run background refresh now": calls the same function the refresh task calls (extract it in phase 4 as
  `BackgroundTasks.refreshWork(deadline:isCancelled:)`; until then, the button can be added in phase 4).
- "Run overnight backup now": the same function `handleProcessing` calls, extracted as
  `BackgroundTasks.processingWork(isCancelled:)`.
- "Pretend the automation ran": runs `BackUpNewPhotosIntent().perform()`.
- A list of the last 20 `RunRecord`s (source, time, seconds, uploaded, remaining).

**Done when:** tests pass, both apps build with no new warnings, and on the iPhone the Background lab lists a `.app`
record after tapping "Back up now".

---

### Phase 2: Automatic backup on, where users already are

**Goal:** new users leave onboarding with automatic backup **on** (they see it and can turn it off). Existing users
with it off are asked once on the Backup tab.

**2.1** `Shared/Views/Onboarding/IntroView.swift`, `FirstBackupView`:
- Add `@State private var autoBackup = true`.
- Below the "safe" message (when `finished` or `returning`), add the card from screen A: a `Toggle` with the title
  "Back up new photos automatically" and the caption "When you open Lelvo, in the background, and overnight."
- Where the screen calls `done()` (the "Start using Lelvo" button), first write
  `UserDefaults.standard.set(autoBackup, forKey: Prefs.Key.autoBackup)`, and set a new
  `Prefs.Key.autoBackupAsked = true`.
- Below the button: "You can change this in Settings." in `.footnote`, `.secondary`.
- Change the success detail copy "Backed up and checked, at full quality. Back up now sends the rest." to "Backed up
  and checked, at full quality." when the toggle is on (the rest starts by itself, phase 3).
- Demo mode (`DemoMode.isActive`, App Review): keep the toggle but don't start real uploads (the engine already
  guards demo mode).

**2.2** `Shared/Views/Backup/BackupDashboardView.swift`: card B at the top of the first `Section` when
`!Prefs.autoBackup && !Prefs.autoBackupAsked`. "Turn on" sets both keys, shows `ToastCenter.shared.show(.info,
"Automatic backup is on")` and calls `ContinuedBackup.start(everything: true)`. "Not now" sets
`autoBackupAsked = true` only. Use `@AppStorage` for both keys, like the other toggles in that view.

**2.3** `Preferences.swift`: add `autoBackupAsked` (default `false`) to `Prefs.Key` and the defaults dictionary.
**Don't change the default of `autoBackup`**: existing users who never saw the question get card B; new users get
the onboarding toggle.

**2.4** Settings footer (`SettingsView.swift` around line 60): replace the "on" text with "Lelvo backs up when you
open it, in short background moments and overnight." Keep the "off" text.

**Tests:** none in Core (UI only). Run `grep -rn "sends the rest\|Back up new photos automatically" UITests/` and
update any UI test that asserts the old copy or taps the old toggle.

**Device check:** the owner's account already finished onboarding, so to see screen A use the UI test or a simulator.
On the iPhone: if the owner's `autoBackup` is off, card B shows; "Turn on" starts a backup. Screenshots of A and B in
light and dark for the PR.

**Done when:** a new install ends onboarding with automatic backup on, and card B works and never comes back after
an answer.

---

### Phase 3: Back up when the app opens

**Goal:** with automatic backup on, opening Lelvo starts backing up new photos at once, and on iOS 26 it keeps going
after leaving, with the system progress indicator (`ContinuedBackup` already does this for "Back up now").

**3.1** `iOS/App/LelvoApp.swift`, `.onChange(of: scenePhase)`, case `.active`, after `ContinuedBackup.resumeIfPending()`:

```swift
// Automatic backup: start on open so new photos go up without a tap (Google Photos does the same).
if Prefs.autoBackup, !Prefs.backupPaused { AutoStart.onOpen() }
```

**3.2** New small type in `Shared/Services/BackgroundTasks.swift` (iOS part):
`enum AutoStart { @MainActor static func onOpen() }`, which:
- returns at once if `BackupActivity.shared.isRunning || .isStarting` or the engine `isRunning`;
- returns if the last auto-start was less than 5 minutes ago (keep the time in a `static var`, not in Prefs);
- then, off the main thread, checks for work: `env.engine.blocker()` is nil (it's `@MainActor`, call it there) **and**
  (queued items exist, or `enqueueNewAssets(force: false)` found new photos). Use `Task.detached` for the PhotoKit
  and SQLite part;
- if there's work: `ContinuedBackup.start(everything: true)`. If not: do nothing (no system indicator for nothing).
- Log: `appLog("Auto-start on open: 7 new photos")` or `"Auto-start on open: nothing new"`.

**Why the 5-minute guard:** people open and close the app many times. Each continued-processing request shows a system
indicator; one per short visit would be noise.

**Don't** start on open when Wi-Fi only is on and the phone is on mobile data: `blocker()` covers that.

**Device check:** take 3 photos with Camera, open Lelvo: the Backup tab shows "Backing up 3 items…" without a tap.
Leave the app straight away: the iOS 26 progress indicator appears and finishes. The log shows the auto-start line
and a `.continued` run record.

**Done when:** opening with new photos starts a backup, opening with nothing new doesn't, and opening twice within
5 minutes starts at most one.

---

### Phase 4: Background refresh uploads (copied from Ente)

**Goal:** the short background runs iOS gives Lelvo upload new photos, not just sync the index.

**4.1 Core: what goes in a short run.** In `UploadOrder.swift` add:

```swift
/// A background run has about 25 seconds. Photos and small videos only: a big video can't finish, and a half-sent
/// one only wastes the time. Ente does the same (photos only in the background).
public static func forShortRun(_ items: [MediaItem], maxBytes: Int64 = 50 * 1_048_576) -> [MediaItem] {
    sorted(items).filter { $0.kind != .video || $0.fileSize <= maxBytes }
}
```

Check `MediaItem.fileSize` in `Packages/LelvoCore/Sources/LelvoCore/Index/IndexModels.swift` (line ~64) is the
original file's size. If it can be 0 (unknown), treat 0 as "too big" for videos. Tests in a new
`UploadOrderShortRunTests.swift`: photos kept, a 10 MB video kept, a 200 MB video dropped, size 0 video dropped, the
order still photos first.

**4.2 Engine option.** `BackupEngine.run(...)` gets a new parameter `shortRun: Bool = false`. When true, the queue is
`JobQueue(items: UploadOrder.forShortRun(runnableItems(...)))` instead of `runnableItems(...)` (line ~541), and
`completeEarlierBackups` / `makeEarlierScreenCopies` (lines ~596–598) are skipped. Everything else (the gate, pause,
`blocker()`, the two lanes, the deadline check at line ~558) stays the same. Items that don't fit stay queued.

**4.3 The refresh task.** In `BackgroundTasks.swift`, rewrite `handleRefresh`:

```swift
private static func handleRefresh(_ task: BGAppRefreshTask) {
    scheduleRefresh()
    let flag = CancelFlag()
    task.expirationHandler = { flag.cancel() }
    Task {
        await refreshWork(deadline: Date().addingTimeInterval(22), isCancelled: { flag.isCancelled })
        task.setTaskCompleted(success: true)
    }
}

/// Also used by the Background lab (Debug). iOS gives a refresh task about 30 s; stop at 22 s so the index scan and
/// bookkeeping finish before iOS ends the task.
static func refreshWork(deadline: Date, isCancelled: @escaping @Sendable () -> Bool) async {
    let env = AppEnvironment.shared
    guard env.isConfigured, (try? await env.td.waitUntilReady(timeout: 10)) != nil else { return }
    if Prefs.autoBackup, !Prefs.backupPaused {
        let started = Date()
        let s = await env.engine.run(deadline: deadline, shortRun: true, isCancelled: isCancelled)
        Prefs.record(RunRecord(source: .refresh, startedAt: started, seconds: Date().timeIntervalSince(started),
                               uploaded: s.uploaded, remaining: s.remaining))
        appLog("Run (refresh): \(s.text)")
    } else {
        _ = try? await env.library.scan(full: false)
    }
    await env.enforceCacheLimits()
}
```

(`engine.run` already does `library.scan(full: false)` before uploading, so don't scan twice.)

**4.4 Schedule every 15 minutes.** `scheduleRefresh()`: `earliestBeginDate = Date().addingTimeInterval(15 * 60)`.
iOS still decides when it runs; asking more often doesn't cost battery, iOS simply won't run it more often than it
wants. It favours apps people open often.

**4.5 Info.plist:** nothing new. `fetch` and `processing` are in `UIBackgroundModes`, and the identifiers are in
`BGTaskSchedulerPermittedIdentifiers` (`project.yml` around line 87). Edit `project.yml`, never the generated project.

**Device check:**
- Background lab → "Run background refresh now" with 3 new photos: they upload within 22 s; the record says
  `refresh`, uploaded 3.
- Real life: leave automatic backup on, take some photos, don't open Lelvo for a day. Then copy the log (see
  "Testing on the owner's iPhone") and count the `Run (refresh)` lines with uploaded > 0. Put the count in the PR.
- Optional, when the owner has Xcode attached: pause in the debugger and run
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.lelvo.ios.index.refresh"]`
  then continue. (Private debugging hook from Apple's docs; Debug sessions only.)

**Done when:** background refresh uploads photos and small videos in real background runs on the iPhone, and never
starts a big video.

---

### Phase 5: Background processing, like Proton

**Goal:** the long background task runs whenever iOS allows, not only on the charger, and comes back quickly while
work is left.

**5.1** `scheduleProcessing()` in `BackgroundTasks.swift`:
- `request.requiresExternalPower = Prefs.chargingOnly` (today it's always `true`).
- `request.requiresNetworkConnectivity = true` (unchanged).
- `earliestBeginDate`: `nil` (as soon as iOS likes) when items are waiting, otherwise `Date() + 60 * 60`. Find "items
  waiting" with a cheap count: `try? AppEnvironment.shared.store.counts()` → `.queued + .uploading > 0`. If that's
  SQLite on the main thread at the call site, move the call into `Task.detached`.

**5.2** `handleProcessing`: extract the body into `static func processingWork(isCancelled:) async` (used by the
Background lab), record a `.processing` `RunRecord`, and reschedule **after** the run (with the new waiting count),
not before. Keep the search indexing after it, but only while charging
(`if Device.isCharging { await env.search.index(...) }`), like the Mac code does: indexing on battery isn't worth it.

**5.3** Night summary flag: if the run started between 22:00 and 07:00 local time, mark it `overnight` for phase 9's
text. Keep the hour check in Core (`BackgroundRuns.isOvernight(_ date: Date, calendar: Calendar) -> Bool`) with a
test.

**Device check:** with "Only while charging" off, leave the phone unplugged on Wi-Fi with 30+ photos waiting: within a
few hours the log shows a `Run (processing)` line. With it on, it only runs on the charger.

**Done when:** processing runs off the charger when the user allows it, and is rescheduled immediately while work is
waiting.

---

### Phase 6: The Camera automation action

**Goal:** "Back Up New Photos" is fast and silent when run from an automation, and Lelvo knows it ran (for "✓ Working").

**6.1** `iOS/Intents/BackupIntents.swift`, `BackUpNewPhotosIntent.perform()`:
1. **Exit early when there's nothing to do** (it runs every time Camera closes): off the main thread, if
   `env.engine.enqueueNewAssets(force: true) == 0` and nothing is queued, record a `.shortcut` `RunRecord` with
   uploaded 0, and return `.result(value: "Everything is backed up.", dialog: "Everything is backed up.")` without
   starting TDLib.
2. Otherwise `env.td.start()`, then `engine.run(deadline: Date() + 25, includeNew: true, shortRun: true)` (phase 4's
   short run: photos and small videos; big videos wait for the night).
3. Record the `.shortcut` `RunRecord` **in both cases**, so "✓ Working" shows even when nothing was new.
4. `BackgroundTasks.scheduleAll()` (unchanged).
5. Respect `Prefs.backupPaused`: `engine.run` returns its "paused" error; still record the run.

Keep the intent's title, phrases and return type: people may already use it in their own shortcuts.

**6.2** Keep the description honest: "Backs up new photos to your Telegram library for about 25 seconds without
opening Lelvo. Use it in a Camera automation so new photos go up within a minute."

**6.3 Is the dialog shown in an automation?** With "Run Immediately" and "Notify When Run" off, iOS doesn't show the
dialog. Check this on the device and note the result in the PR. If iOS does show it, return `.result()` without a
dialog when the intent runs from an automation. There's no API to tell the two apart, so in that case drop the dialog
for everyone, and keep the `ReturnsValue` so shortcuts can still use the text.

**Device check:** set up the automation by hand (steps in screen E), take a photo, close Camera. Within a minute the
log shows `Run (shortcut)` with uploaded 1, and the photo shows as backed up in Lelvo. Close Camera again without
taking a photo: a `Run (shortcut)` with uploaded 0 in under 2 s.

**Done when:** the automation backs up a fresh photo within about a minute, and closing Camera with nothing new costs
about a second.

---

### Phase 7: Explainer and guided setup screens

**Goal:** screens D, E and F, exactly as written above.

**7.1 Preview first** (owner rule: HTML preview with stock photos before UI code). Make one HTML page with D, E and F
in iPhone frames, light and dark, with the real copy. Publish it for the owner and **wait for approval** before
writing SwiftUI.

**7.2 Pictures for the steps.** The owner records the Shortcuts app on the iPhone (Control Center → Screen
Recording) doing the 7 steps once in light mode and once in dark mode, and sends the files. Cut one still per step
(PNG, 3x, about 1,170 px wide, status bar cropped, no personal automations visible) into
`iOS/Resources/AutomationGuide/step1-light.png` … `step7-dark.png`. Add them as an asset catalog
(`iOS/Resources/AutomationGuide.xcassets`, one image set per step with light and dark appearances) so iOS picks the
right one. Until they exist, use an SF Symbol per step (`square.grid.2x2`, `plus.circle`, `app`, `camera`,
`xmark.app`, `bolt`, `icloud.and.arrow.up`) so the screens work.

**7.3 Code.** New files in `iOS/Views/Backup/` (iOS only, the Mac has no Shortcuts automations for Camera):
- `AutomaticBackupExplainerView.swift`: screen D. A `List` with `.insetGrouped` style.
- `AutomationSetupView.swift`: screen E. `TabView(selection:)` with `.tabViewStyle(.page(indexDisplayMode: .always))`,
  one page per step, image on top (max height 55% of the screen, `.scaledToFit`, rounded 20 pt corners, a hairline
  border), text below, then buttons. "Open Shortcuts":
  `UIApplication.shared.open(URL(string: "shortcuts://")!)`. Bold words with `Text("Tap **Automation** …")`
  (Markdown in `LocalizedStringKey`).
- `AutomationCheckView.swift`: screen F. Polls `Prefs.runRecords` every 2 s for a `.shortcut` record newer than when
  the screen opened (and refreshes on `scenePhase == .active`); stops after 3 minutes. `Haptics.success()` on
  success.
- All text supports Dynamic Type (no fixed heights on text), VoiceOver labels on the images ("Step 3 of 7. In
  Shortcuts, tap App."), and Reduce Motion (no auto-advance).

**Device check:** go through all steps on the iPhone in light and dark mode, with the largest text size. "Open
Shortcuts" opens the app; coming back keeps the step. Screenshots for the PR.

**Done when:** a person who never used Shortcuts can set up the automation from these screens alone. Ask one
non-technical person to try it; note in the PR where they hesitated.

---

### Phase 8: Offer at the right moment, and show whether it works

**Goal:** card C appears once the user trusts Lelvo, and Settings row G shows "Set up", "Working ✓" or "Seems off".

**8.1 When to show card C** (Backup tab, below card B's place). All must be true:
- iOS (not Mac), `Prefs.autoBackup == true`;
- the first full backup is done: nothing waiting (`stats.pending == 0 && stats.notQueued == 0`) at least once. Store
  `Prefs.Key.firstFullBackupAt` the first time it happens;
- `BackgroundRuns.automationHealth(...)` is `.notSetUp`;
- not snoozed: `Prefs.Key.automationOfferSnoozedUntil` is nil or in the past, and `automationOfferDismissals < 3`.
"Not now": snooze 21 days and count one dismissal. "Show me how": push screen D.
Put the "should show" rule in Core (`BackgroundRuns.shouldOfferAutomation(...)`) with tests.

**8.2 Settings row G** (`SettingsView.swift`, Backup section, iOS only), under the toggle: "Faster backup" with value
"Set up" / "Working" (green `checkmark.circle.fill`) / "Seems off" (orange `exclamationmark.triangle.fill`). Pushes
screen D; when "Seems off", D starts with the line from screen G and a **Fix** button that pushes E.
- `newestPhotoDate` for the health check: the creation date of the newest asset in Photos, off the main thread
  (`PhotoLibraryService`; add a small `newestAssetDate()` if there isn't one).

**Device check:** with the automation set up and working: "Working". Turn the automation off in Shortcuts, take
photos for a while (or set the device date forward in a Debug build only): "Seems off". Card C shows once after a
full backup, and "Not now" hides it.

**Done when:** the offer appears at the right time only, and Settings always tells the truth about the automation.

---

### Phase 9: Notifications (copied from Proton)

**Goal:** a quiet morning summary and a gentle reminder when the backup is stuck. Never more than one at a time.

**9.1 Permission.** Ask only when it makes sense, never at launch:
- on the last page of screen F after "It works" ("Tell me when backups finish" button), and
- as a Settings toggle "Backup notifications" (Backup options screen), which asks the first time it's turned on.
Use `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`. If denied, the toggle
explains: "Turn on notifications for Lelvo in Settings." with a button that opens the app's Settings page.

**9.2 Morning summary.** After a `.processing` or `.refresh` run where uploaded > 0 and the run was `overnight`
(phase 5), post a local notification with `BackgroundRuns.summaryText(...)`. Add counts from all overnight runs of
that night together: keep a running total in Prefs and post once, at the first run after 07:00 or when the app opens.
`threadIdentifier = "lelvo.backup.summary"` and a fixed identifier, so a newer summary replaces the older one.

**9.3 Stuck reminder.** At the end of every background run, compute `BackgroundRuns.nextReminder(...)`; if it's in
the past and items are waiting, post "Backup waiting" (screen H) and increment `remindersSent`. Reset to 0 after any
run with uploaded > 0. Fixed identifier, so they never pile up.

**9.4 Tapping a notification** opens the Backup tab (`AppModel.shared.selectedTab = .backup`). Set the
`UNUserNotificationCenter` delegate in `AppDelegate`.

**9.5 Privacy:** notifications contain only counts. Never names, places, dates or library names.

**Tests:** Core tests for the backoff and text are in phase 1; add one for adding up the night's counts.

**Device check:** Background lab → "Run overnight backup now" at night with photos waiting shows the summary.
Pausing the backup for 2+ days (or a Debug date override) shows the reminder once.

**Done when:** the summary and reminder each appear at most once at a time, only with permission, and open the Backup
tab.

---

### Phase 10: Words everywhere, full device test, release

**10.1 Docs:**
- `docs/ARCHITECTURE.md`: update the "Background" row and the "Background reality on iOS" paragraph: refresh
  uploads (short runs, photos and small videos), processing off the charger unless "Only while charging", auto-start
  on open, the Camera automation, notifications.
- `docs/FAQ.md`, under "## Backing up": add "Why doesn't Lelvo back up in the background like Google Photos?" (the
  why from screen D, three short paragraphs) and "How do I set up faster backup?" (the 7 steps, text only).
- `docs/CHANGELOG.md`, `## Unreleased`: one plain line per user-visible change. The hook regenerates `website/`.
- `PRIVACY.md`: notifications are local; no new data leaves the phone. Only change it if a sentence there is now
  wrong.

**10.2 Full device test**, on the owner's iPhone, signed in, over at least 2 days (write the results in the PR):
1. New photos while the app is closed for a day reach the library through `refresh` runs (count them).
2. Overnight, unplugged with "Only while charging" off: a `processing` run uploads what was left, videos included.
3. Camera automation: 5 photos, each backed up within about a minute.
4. Opening the app with new photos starts a backup without a tap; leaving shows the progress indicator.
5. Morning summary once; stuck reminder after a 2-day pause.
6. Settings shows "Working", and "Seems off" after turning the automation off.
7. Battery: Settings → Battery shows Lelvo's background use. Note the percentage for a normal day. If it's more than a
   few percent, the 15-minute refresh request is too eager: try 30 minutes.
8. Pause, Wi-Fi only and charging only are respected in every path (check the log for no uploads while blocked).

**10.3 Release:** follow `docs/RELEASING.md`. TestFlight first; ask external testers to set up the automation and
report.

**Done when:** all 8 checks pass on the owner's iPhone, docs match what the app does, and the owner approves.

---

## Testing on the owner's iPhone (never sign out)

The owner is signed in to a real Telegram account with a real library. **Never sign out, never delete the app, never
reinstall from scratch, never reset the simulator state on the device.** Installing over the existing app keeps the
sign-in, the keychain, TDLib's session and the index.

The team id and the device id are in `CLAUDE.local.md` (not in git). Never write them into this file or a commit.

1. Build a Debug app for the device into the **same** `build/DerivedData` folder every time:
   ```sh
   xcodebuild -project Lelvo.xcodeproj -scheme Lelvo -configuration Debug -destination 'generic/platform=iOS' \
     -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
     DEVELOPMENT_TEAM=<team id from CLAUDE.local.md> -allowProvisioningUpdates build > build/device.log 2>&1
   tail -5 build/device.log
   ```
   (Run `Scripts/build.sh ios` once first if `Lelvo.xcodeproj` doesn't exist; it's generated from `project.yml`.)
2. Install over the existing app (keeps everything):
   ```sh
   xcrun devicectl device install app --device <device id> build/DerivedData/Build/Products/Debug-iphoneos/Lelvo.app
   ```
3. **Don't launch the app.** The owner may be using the phone. Tell the owner what to do ("open Lelvo, take 3
   photos, close Camera, wait a minute").
4. Read the log from the phone:
   ```sh
   mkdir -p build/devicelogs
   xcrun devicectl device copy from --device <device id> --domain-type appDataContainer \
     --domain-identifier app.lelvo.ios --source "Library/Application Support/Logs/lelvo.log" \
     --destination build/devicelogs/lelvo.log
   grep -E "Run \(|Auto-start|Backup run|Backup stopped" build/devicelogs/lelvo.log | tail -40
   ```
5. Only report what the log shows. If something didn't happen, say so.

Debug builds include the Background lab (phase 1.5) for triggering runs by hand. Release builds never include it.

---

## Not doing (and why)

- **Apple's photo backup extension** (`PHBackgroundResourceUploadExtension`): it uploads the original photo
  unencrypted to a fixed HTTPS server. That breaks end-to-end encryption.
- **A server for silent push** (what Ente does hourly): Lelvo has no server, by design. Revisit only if the phase 10
  numbers show the no-server version isn't enough, and as its own approved issue.
- **Telegram push** (`registerDevice`): Telegram's servers would need our Apple push certificate, and there's no clear
  way to set that up for a third-party app.
- **Location wake-ups** ("Always" location, like PhotoSync): a privacy prompt in a privacy app, for 30 s to 3 min of
  time. Not worth it.
- **Silent audio or other keep-alive tricks:** App Review rejects them.
- **The charger automation** (opens Lelvo briefly when plugging in): phase 5's processing covers charging without the
  app flashing open.
- **Bot API uploads through background `URLSession`:** a bot per user, a 50 MB cap, the retired v1 client, and a
  second upload system.
- **Control Center / Lock Screen "Back Up Now" button:** needs iOS 18 and a widget extension target (we support
  iOS 17 and have no widget target). Good follow-up, as its own issue.

## Sources

- Apple: [Uploading asset resources in the background](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background),
  [WWDC25: Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/)
- Ente: [`push.go`](https://github.com/ente-io/ente/blob/main/server/pkg/controller/push.go),
  [`background_tasks.dart`](https://github.com/ente-io/ente/blob/main/mobile/apps/photos/lib/utils/background_tasks.dart),
  [Background sync help](https://help.ente.io/photos/features/background)
- Proton Drive: [`BackgroundModes`](https://github.com/ProtonDriveApps/ios-drive/tree/main/ProtonDrive-iOS/ProtonDrive/BackgroundModes)
- PhotoSync: [Autotransfer](https://www.photosync-app.com/premiumwork)
- Immich: [Automatic backup](https://docs.immich.app/features/automatic-backup)
- Telegram: [Push notifications](https://core.telegram.org/api/push-updates)
