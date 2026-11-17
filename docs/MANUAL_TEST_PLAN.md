# Manual test plan — Free (Phase 1→N) and Pro

Hand checklist for shipping a stable Lelvo on **iPhone**, **Android** and **Mac** — one app on three platforms.
Use this before App Store / Play release, after big backup or crypto changes, and when Pro ships.

Related: [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md) (store paperwork), [ANDROID_PLAN.md](ANDROID_PLAN.md)
(Android build order and write-safety), `marketing/PRO_STRATEGY.md` (Free vs Pro rules — not in git).

---

## How to use this

1. **One scenario at a time.** Tick the box only after you saw it pass on that device.
2. **Same build** you will ship (TestFlight / internal track / release candidate). Demo mode alone is not enough.
3. **Log failures** with the template in "When something breaks" below.
4. **Android write safety:** until Phase 15 (cross-platform gate) is green, backups / deletes / notes go to an
   **"Android test"** library only. Reading the real library is fine.
5. **Never test Free Up Space** on irreplaceable photos. Use disposable shots you have verified in Telegram.

### Severity (what blocks release)

| Level | Meaning | Examples |
|---|---|---|
| **S0 — Block ship** | Data loss, false “backed up”, lockout, silent delete | Incomplete upload marked done; Free Up deletes without confirm; recovery key unlock fails |
| **S1 — Block this platform** | Core flow broken on one OS | Sign-in stuck; viewer black for all cloud items; resume after kill duplicates everything |
| **S2 — Fix before wide users** | Trust or money path broken | Paywall traps Free; Restore Purchases fails; cross-device note sync wrong |
| **S3 — Polish** | World-class bar, not day-one trust | Scrubber hitch, dark-mode tint, empty-state wording |

**Ship bar:** all S0 must be green on iPhone, Android and Mac. S1 green on that platform. S2 green before Pro ads.
S3 you can schedule — but a “world-class” claim means you keep burning them down.

### Devices (fill in)

| Device | OS | Build | Role |
|---|---|---|---|
| iPhone | | | Primary Free + App Review path |
| Android phone | | | Primary Free + Play internal |
| Second phone / emulator | | | Cross-device / older OS |
| Mac (optional) | | | Viewer / restore / folder backup later |

Columns in checklists: **iOS** · **And** · **Mac** · **Notes**. Replace a box with `☑` for pass, `✗` for fail (then
send the bug), `—` for not applicable. Pre-filled `—` means the row cannot apply there; change it if it does.
Mac-only rows are in Phase M (ids `Mac.n`).

### Current focus (owner, 2026-11-17): stability first

Pro testing (Phase 16) is **parked**. Order of work:

1. **Phase 0** before every session (automated, minutes).
2. **Phase 1 + T + D + C** — trust: no lost photo, no false "backed up", no Telegram flag, counts right.
3. **Phase L + P** — interruptions and a 40k library.
4. Phases 2–15 and M.

A bug found on one platform is checked on the other two before the row is ticked.

### When something breaks: send Claude this

Paste one message per bug. Claude fixes it on all three platforms and adds a test where it can.

```
Row:      T.4  (the row id)
Device:   iPhone 16 Pro · iOS 26.1 · build 1.4 (57)
Did:      terminated the Lelvo session in Telegram > Devices while a backup ran
Saw:      spinner forever on Backup tab
Expected: signed-out screen, queue kept
Time:     14:32 (so the log line can be found)
Attach:   screenshot(s) + log
```

How to get the log:

- **iPhone:** Settings → Share logs, or tell Claude "pull the iPhone log" (it reads `lelvo.log` from the app
  container with `devicectl`; nothing is relaunched).
- **Android:** Settings → Share logs, or tell Claude "pull the emulator log" (`adb logcat` + app log file).
- **Mac:** Settings → Share logs.
- **Telegram side:** a screenshot of the channel around the item (captions are fine, they hold no secrets in E2E).

---

## Phase 0 — Automated gate (run before every manual session)

If any line fails, fix it first. Manual testing on a red build wastes the session.

| # | Check | Command / how | Status | Today |
|---|---|---|---|---|
| 0.1 | Core unit tests (format, crypto, queue, index, takeout) | `Scripts/build.sh test` | exists | ☐ |
| 0.2 | iOS build, no new warnings | `Scripts/build.sh ios > build/ios.log 2>&1; Scripts/check-warnings.sh build/ios.log` | exists | ☐ |
| 0.3 | Mac build, no new warnings | same with `mac` | exists | ☐ |
| 0.4 | Android JVM tests + debug build + emulator install | `/android-verify` | exists | ☐ |
| 0.5 | iOS UI tests (demo library: grid, viewer, backup buttons, trash, video close) | `Scripts/build.sh uitest` | exists | ☐ |
| 0.6 | Mac UI tests (buttons, sections, scale) | `xcodebuild -project Lelvo.xcodeproj -scheme LelvoMac test > build/macui.log 2>&1` | exists | ☐ |
| 0.7 | Format test vectors open on all three platforms | `Scripts/build.sh test` + Android `VectorsTest`, `VectorFilesTest` | exists | ☐ |
| 0.8 | Log scan: no secrets, FLOOD_WAIT honoured, no error bursts | `Scripts/check-log.sh <log>` | **to build** | ☐ |
| 0.9 | Release build has no debug hooks | `strings` on release binary for `-UITest`, `-autoScrollTest`, debug unlock | **to build** | ☐ |
| 0.10 | Copy lint: no "!", TODO, "beta", "Memvo" in user text (except crypto labels) | grep over strings / `strings.xml` | **to build** | ☐ |

---

## Phase 1 — Trust core (never lose a photo)

Goal: nobody can lose photos or be lied to about backup. If anything here fails, stop.

| # | Scenario | How to test | Breaks if… | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|---|
| 1.1 | Fresh install launches | Delete app → install RC → open light + dark | Crash, blank, wrong “signed in” | ☐ | ☐ | ☐ |  |
| 1.2 | Real Telegram sign-in | Number → code → 2FA → home | Stuck spinner, wrong errors, no session | ☐ | ☐ | ☐ |  |
| 1.3 | Session survives kill | Force-quit → reopen within a minute | Asks for code again every time | ☐ | ☐ | ☐ |  |
| 1.4 | Open / create encrypted library | Create or unlock; write recovery key on paper; confirm | Key skipped; unlock with wrong key; crash | ☐ | ☐ | ☐ |  |
| 1.5 | Recovery key after reinstall | Reinstall → sign in → unlock with recovery key only | Lockout; treats fail as “no library” | ☐ | ☐ | ☐ |  |
| 1.6 | Photos permission: denied | Deny → still open cloud library | Trapped behind permission wall | ☐ | ☐ | ☐ |  |
| 1.7 | Photos permission: limited / partial | Select few photos → Backup + grid behave | Crash; backs up without access | ☐ | ☐ | ☐ |  |
| 1.8 | Photos permission: full | Grant → phone items appear | Empty forever | ☐ | ☐ | ☐ |  |
| 1.9 | Small real backup | 1 photo + 1 Live/Motion + 1 short video → Back up now → check Telegram + re-scan | Marked done incomplete; missing parts | ☐ | ☐ | ☐ |  |
| 1.10 | Kill mid-backup | Kill at ~50% → reopen → resume | Duplicates; stuck; false complete | ☐ | ☐ | ☐ |  |
| 1.11 | Airplane mid-backup | Airplane → online → resume | Crash; silent success; endless hang | ☐ | ☐ | ☐ |  |
| 1.12 | “Backed up” only when confirmed | Compare channel file sizes / parts to caption | UI green while Telegram incomplete | ☐ | ☐ | ☐ |  |
| 1.13 | Free Up Space — one disposable | Verify in Telegram → Free Up → cancel once → confirm once | Deletes without confirm; deletes non-backed-up | ☐ | ☐ | ☐ |  |
| 1.14 | Sign out and reset | Sign out → data gone → sign in → unlock → library intact in Telegram | Half-cleared session; library wiped | ☐ | ☐ | ☐ |  |
| 1.15 | Upgrade over the live build | Install current TestFlight / store build → back up → install RC over it (no delete) | Library won't open; queue lost; re-uploads all | ☐ | ☐ | ☐ |  |
| 1.16 | Old library still opens | Open a library made by the oldest build you shipped (and an old Standard one if you have it) | "Incompatible"; asks to repair; wrong key error | ☐ | ☐ | ☐ |  |
| 1.17 | New data readable by old build | Back up with RC → open same library on a device still on the older build | Old build crashes or hides new items | ☐ | ☐ | ☐ |  |
| 1.18 | Reinstall rebuilds index | Note counts → delete app → reinstall → sign in → unlock → wait for scan | Counts differ; items shown twice; anything re-uploaded | ☐ | ☐ | ☐ |  |
| 1.19 | Byte-exact round trip | Back up a photo + video → delete from phone → Save to phone → compare size/SHA with original (AirDrop to Mac, `shasum`) | Different bytes; lost date/place/Live pairing | ☐ | ☐ | ☐ |  |
| 1.20 | Photo deleted while queued | Queue 20 → delete 3 from Photos mid-run | Crash; stuck job; "failed" forever | ☐ | ☐ | ☐ |  |
| 1.21 | Photo edited after backup | Back up → edit (crop) in Photos → wait | Edit lost; original overwritten; endless re-upload | ☐ | ☐ | ☐ |  |
| 1.22 | Free Up never touches what Telegram lost | Back up → delete that message in Telegram by hand → open Free Up | Item still offered for delete | ☐ | ☐ | ☐ |  |
| 1.23 | Wrong library cannot eat photos | Two libraries → back up to A → switch to B → Free Up | B offers items that only live in A | ☐ | ☐ | ☐ |  |

**Phase 1 pass:** every row green on the platform you are shipping.

---

## Phase T — Telegram safety (never get the account flagged)

Run on a **second Telegram account** first if you have one. After the long runs, message **@SpamBot** in Telegram:
it must say the account has no limits.

| # | Scenario | How to test | Breaks if… | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|---|
| T.1 | FLOOD_WAIT under load | Back up 500+ small photos in one go; read log | Any request sent during a wait; wait shorter than told; retry loop | ☐ | ☐ | ☐ |  |
| T.2 | Two uploads at most | Watch log / Backup lanes during T.1 | Three or more parts in flight | ☐ | ☐ | ☐ |  |
| T.3 | Quiet launch | Cold launch with a big library; count TDLib calls in first minute of log | Hundreds of history/file calls; full-channel scan on every launch | ☐ | ☐ | ☐ |  |
| T.4 | Session ended from Telegram | Telegram → Settings → Devices → end Lelvo session (idle, then mid-backup) | Spinner forever; crash; local photos or queue wiped | ☐ | ☐ | ☐ |  |
| T.5 | Lelvo session name | Telegram → Devices | Shows something odd or another app's name | ☐ | ☐ | ☐ |  |
| T.6 | Only our channel touched | Before/after: other chats' unread counts, archive, mute, read marks | Any other chat marked read, joined, muted or messaged | ☐ | ☐ | ☐ |  |
| T.7 | Message deleted by hand in channel | Delete one item's message(s) in Telegram → re-scan | Still "backed up"; crash; Free Up offers it | ☐ | ☐ | ☐ |  |
| T.8 | Junk posted in channel | Post a text, a sticker and a random photo in the channel → re-scan | Counted as library items; crash; scan stops | ☐ | ☐ | ☐ |  |
| T.9 | Channel deleted or left | Delete the library channel in Telegram (test account only) | Silently makes a new library; claims items backed up | ☐ | ☐ | ☐ |  |
| T.10 | 2 GB vs 4 GB file limit | File just over 2 GB on a non-Premium account | Upload rejected and retried forever instead of split | ☐ | ☐ | ☐ |  |
| T.11 | Two devices back up at once | iPhone + Android same library, both "Back up now" | Duplicates; FLOOD_WAIT storm; one device's notes lost | ☐ | ☐ | ☐ |  |
| T.12 | Long run | 2 hours / 2k items unattended | FLOOD waits growing; account limited (@SpamBot); memory climbing | ☐ | ☐ | ☐ |  |
| T.13 | Telegram app open on same phone | Use official Telegram during a backup | Either app logged out; Lelvo stalls | ☐ | ☐ | — |  |
| T.14 | VPN / proxy on | Common VPN on | Endless "connecting"; no clear message | ☐ | ☐ | ☐ |  |
| T.15 | Data used is sane | Settings → Cellular (iOS) / Data usage (Android) after a session of browsing | Cloud items downloaded again on every open | ☐ | ☐ | — |  |

---

## Phase D — Media edge cases (every kind of photo survives)

One item of each kind is enough. After backup: open on the other platform, then Save to phone and check it.

| # | Item | Check | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| D.1 | iCloud "Optimize Storage" photo (original not on phone) | Downloads original, backs up full size; offline → waits with reason | ☐ | — | ☐ |  |
| D.2 | iCloud video not on phone, on cellular with Wi‑Fi only on | Waits, does not fail forever | ☐ | — | ☐ |  |
| D.3 | Shared album / Hidden album / screenshots / screen recordings | Backed up or skipped as the setting says | ☐ | ☐ | ☐ |  |
| D.4 | RAW / ProRAW / DNG, RAW+JPEG pair | Both resources kept | ☐ | ☐ | ☐ |  |
| D.5 | ProRes / 4K60 / HDR (Dolby Vision) video | Plays HDR; size matches | ☐ | ☐ | ☐ |  |
| D.6 | Slo-mo, time-lapse, Cinematic, spatial video | Original kept; plays | ☐ | ☐ | ☐ |  |
| D.7 | Portrait (depth), panorama, burst (picked + all) | Depth/edits not lost; burst handled as designed | ☐ | ☐ | ☐ |  |
| D.8 | 1-second video and 1-hour video | Both complete; long one splits and streams | ☐ | ☐ | ☐ |  |
| D.9 | File over 4 GB | Splits; re-scan complete; plays | ☐ | ☐ | ☐ |  |
| D.10 | No EXIF date / date 1970 / future date | Lands on a sane day; no crash in grouping | ☐ | ☐ | ☐ |  |
| D.11 | Taken abroad (other time zone) | Same day on all three platforms | ☐ | ☐ | ☐ |  |
| D.12 | Same name `IMG_0001.JPG` from two cameras | Both kept, no overwrite | ☐ | ☐ | ☐ |  |
| D.13 | Unicode / emoji / very long file name | Backs up; Save to phone keeps a valid name | ☐ | ☐ | ☐ |  |
| D.14 | WhatsApp / Downloads / SD card folders (Android) | Found; backed up per folder choice | — | ☐ | — |  |
| D.15 | Corrupt / 0-byte file | Marked failed with reason; queue continues | ☐ | ☐ | ☐ |  |
| D.16 | Photo with location stripped | No fake place | ☐ | ☐ | ☐ |  |

---

## Phase C — Counts (the numbers are always right)

Write the numbers down. Same library, same moment.

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| C.1 | Phone count matches Photos app | Lelvo "on this phone" vs Photos / Gallery count | ☐ | ☐ | — |  |
| C.2 | Library count same on all three | Backed-up total on iPhone, Android, Mac | ☐ | ☐ | ☐ |  |
| C.3 | Stable across relaunch | Kill → reopen 3 times | ☐ | ☐ | ☐ |  |
| C.4 | Waiting + backed up + failed = total | Backup tab adds up | ☐ | ☐ | ☐ |  |
| C.5 | After delete / recover / Free Up | Each count moves by exactly the number touched | ☐ | ☐ | ☐ |  |
| C.6 | No flicker | Counts never jump to 0 or double during a scan | ☐ | ☐ | ☐ |  |
| C.7 | After reinstall (1.18) | Same numbers as before | ☐ | ☐ | ☐ |  |
| C.8 | Live Photo / Motion counted once | Not as two items | ☐ | ☐ | ☐ |  |

---

## Phase L — Interruptions (life happens mid-backup)

Start a backup of ~50 items, do the thing, then check: no duplicate, no false "backed up", it finishes.

| # | Interruption | iOS | And | Mac | Notes |
|---|---|---|---|---|---|
| L.1 | Lock the screen for 10 min | ☐ | ☐ | — |  |
| L.2 | Phone call / FaceTime | ☐ | ☐ | — |  |
| L.3 | Low Power Mode / Battery Saver on | ☐ | ☐ | ☐ |  |
| L.4 | Wi‑Fi → cellular → Wi‑Fi switch | ☐ | ☐ | ☐ |  |
| L.5 | Restart the phone | ☐ | ☐ | ☐ |  |
| L.6 | Phone storage nearly full | ☐ | ☐ | ☐ |  |
| L.7 | Photos access revoked in Settings | ☐ | ☐ | ☐ |  |
| L.8 | Sign out during backup | ☐ | ☐ | ☐ |  |
| L.9 | Switch library during backup | ☐ | ☐ | ☐ |  |
| L.10 | Device clock changed by hours | ☐ | ☐ | ☐ |  |
| L.11 | App swiped away, reopened after 1 day | ☐ | ☐ | ☐ |  |
| L.12 | Phone hot (charging + sun) / thermal throttle | ☐ | ☐ | — |  |
| L.13 | Mac sleeps / lid closed | — | — | ☐ |  |

---

## Phase P — Performance (40k-photo library)

Use the biggest real library you have, or a seeded one (see Automation). Polished-product bar: no stutter.

| # | Check | Target | iOS | And | Mac | Notes | Today |
|---|---|---|---|---|---|---|---|
| P.1 | Cold launch to grid | under 2 s | ☐ | ☐ | ☐ |  | ☐ |
| P.2 | Fast scroll top → bottom | no hitch, no blank cells after stop | ☐ | ☐ | ☐ |  | ☐ |
| P.3 | Scrubber drag across years | label and grid keep up | ☐ | ☐ | ☐ |  | ☐ |
| P.4 | Open viewer on cloud item | first image under 1 s on Wi‑Fi | ☐ | ☐ | ☐ |  | ☐ |
| P.5 | Memory after 10 min browsing | stays flat, no growth per swipe | ☐ | ☐ | ☐ |  | ☐ |
| P.6 | Main-thread hangs | Xcode Organizer / Instruments Hangs; Android StrictMode / ANR = 0 | ☐ | ☐ | ☐ |  | ☐ |
| P.7 | Battery for 1 h backup | note %; compare with Google Photos doing the same | ☐ | ☐ | — |  | ☐ |
| P.8 | App cache size | stays bounded; Clear cache frees it | ☐ | ☐ | ☐ |  | ☐ |
| P.9 | Launch does no whole-library read | log shows incremental Photos change fetch | ☐ | ☐ | ☐ |  | ☐ |
| P.10 | Tab switches | instant, no spinner on return | ☐ | ☐ | ☐ |  | ☐ |

---

## Phase M — Mac only

| # | Scenario | Pass | Notes |
|---|---|---|---|
| Mac.1 | Sign in, unlock, timeline, viewer, video, save | ☐ |  |
| Mac.2 | Open library written by iPhone and by Android | ☐ |  |
| Mac.3 | Window resize / full screen / multiple windows | ☐ |  |
| Mac.4 | Keyboard: arrows in grid and viewer, Space, ⌘⌫ with confirm | ☐ |  |
| Mac.5 | Save to Photos and Download a copy to Finder | ☐ |  |
| Mac.6 | Sleep / wake mid-download | ☐ |  |
| Mac.7 | Sign out | ☐ |  |

---

## Phase 2 — Sign-in, onboarding, library edge cases

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 2.1 | Intro pages readable, skippable | Walk all intro pages; back/forward | ☐ | ☐ | ☐ |  |
| 2.2 | Wrong login code | Enter bad code → clear message, retry | ☐ | ☐ | ☐ |  |
| 2.3 | Resend code | Wait / tap resend; labels match delivery | ☐ | ☐ | ☐ |  |
| 2.4 | Wrong 2FA password | Clear error; no lockout spam | ☐ | ☐ | ☐ |  |
| 2.5 | No Telegram account | Number with no account → points to Telegram | ☐ | ☐ | ☐ |  |
| 2.6 | Session ended elsewhere | Sign in on second client that ends sessions if available | ☐ | ☐ | ☐ |  |
| 2.7 | Demo / App Review login (iOS) | Review number + code → sample library; Back up now simulates | ☐ | — | — |  |
| 2.8 | Choose among multiple libraries | If several channels exist, pick correct one | ☐ | ☐ | ☐ |  |
| 2.9 | Wrong passphrase | Refuse; no wipe | ☐ | ☐ | ☐ |  |
| 2.10 | Damaged / newer / plain header | Open incompatible library → “incompatible”, never “repair” | ☐ | ☐ | ☐ |  |
| 2.11 | New library shows recovery key once | Must confirm; cannot skip | ☐ | ☐ | ☐ |  |
| 2.12 | Library ready / Welcome back counts | First scan and return visit show sensible counts | ☐ | ☐ | ☐ |  |
| 2.13 | Switch library | Switch → index matches that channel | ☐ | ☐ | ☐ |  |
| 2.14 | Rename library (if offered) | Name updates in Settings and Telegram | ☐ | ☐ | ☐ |  |

---

## Phase 3 — Gallery timeline

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 3.1 | Phone + cloud in one timeline | Mix of local and backed-up; scroll | ☐ | ☐ | ☐ |  |
| 3.2 | Day / month / year grouping | Pinch or zoom levels if available | ☐ | ☐ | ☐ |  |
| 3.3 | Date scrubber | Fast scroll; date label correct | ☐ | ☐ | ☐ |  |
| 3.4 | Status badges | Backed up / waiting / attention colours match legend | ☐ | ☐ | ☐ |  |
| 3.5 | “What the icons mean” | Open help / legend sheet | ☐ | ☐ | ☐ |  |
| 3.6 | Filter: videos | Only videos | ☐ | ☐ | ☐ |  |
| 3.7 | Filter: Live / Motion | Only those kinds | ☐ | ☐ | ☐ |  |
| 3.8 | Filter: favorites | Hearted only | ☐ | ☐ | ☐ |  |
| 3.9 | Filter: only in Telegram | Cloud-only visible | ☐ | ☐ | ☐ |  |
| 3.10 | Filter: not backed up | Waiting / local-only | ☐ | ☐ | ☐ |  |
| 3.11 | Select + swipe-select | Long-press, drag, edge auto-scroll | ☐ | ☐ | ☐ |  |
| 3.12 | Select all in view | Selects expected set | ☐ | ☐ | ☐ |  |
| 3.13 | Multi: back up | Selected upload | ☐ | ☐ | ☐ |  |
| 3.14 | Multi: share | System share sheet | ☐ | ☐ | ☐ |  |
| 3.15 | Multi: favorite | Phone and/or library heart | ☐ | ☐ | ☐ |  |
| 3.16 | Multi: add to album | Existing + new album | ☐ | ☐ | ☐ |  |
| 3.17 | Multi: delete phone | System confirm; only phone | ☐ | ☐ | ☐ |  |
| 3.18 | Multi: delete backup only | Leaves phone; removes from library | ☐ | ☐ | ☐ |  |
| 3.19 | Multi: delete everywhere | Both sides with confirms | ☐ | ☐ | ☐ |  |
| 3.20 | New phone photo appears | Take a photo → appears without reinstall | ☐ | ☐ | ☐ |  |
| 3.21 | Large library scroll | 1k+ items; no crash; usable FPS | ☐ | ☐ | ☐ |  |
| 3.22 | Empty library | New account empty state is clear | ☐ | ☐ | ☐ |  |
| 3.23 | Pull / re-scan | Re-scan does not wipe correct items | ☐ | ☐ | ☐ |  |

---

## Phase 4 — Viewer (photo, Live/Motion, video)

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 4.1 | Swipe between items | Pager keeps place | ☐ | ☐ | ☐ |  |
| 4.2 | Close gesture | Swipe down / back | ☐ | ☐ | ☐ |  |
| 4.3 | Details sheet | Swipe up / info: date, place, camera, size, where | ☐ | ☐ | ☐ |  |
| 4.4 | Zoom + double-tap | Sharp when zoomed | ☐ | ☐ | ☐ |  |
| 4.5 | Screen copy then original | Soft then sharp load for cloud | ☐ | ☐ | ☐ |  |
| 4.6 | Share original | Shared file opens elsewhere | ☐ | ☐ | ☐ |  |
| 4.7 | Save to phone | Lands in Photos / gallery with date | ☐ | ☐ | ☐ |  |
| 4.8 | Favorite from viewer | Syncs to grid | ☐ | ☐ | ☐ |  |
| 4.9 | Delete from viewer | Phone / backup / everywhere paths | ☐ | ☐ | ☐ |  |
| 4.10 | Live Photo play | Press / chip; paired motion | ☐ | — | ☐ |  |
| 4.11 | Motion Photo play | Chip / long press | — | ☐ | — |  |
| 4.12 | Video play / pause | Starts without black forever | ☐ | ☐ | ☐ |  |
| 4.13 | Scrub + frame strip | Seek lands near target | ☐ | ☐ | ☐ |  |
| 4.14 | Mute / speed / ±10 s | Controls work; mute sticks as designed | ☐ | ☐ | ☐ |  |
| 4.15 | Quality pill / fast version | Switch if present; stall fallback | ☐ | ☐ | ☐ |  |
| 4.16 | Resume playback position | Leave mid-video (>2 min) → reopen near same time | ☐ | ☐ | ☐ |  |
| 4.17 | Sound off on close | No audio after leaving viewer | ☐ | ☐ | ☐ |  |
| 4.18 | Place opens Maps | Tap place → maps app | ☐ | ☐ | ☐ |  |
| 4.19 | Neighbour prefetch on Wi‑Fi | Next items open faster | ☐ | ☐ | ☐ |  |
| 4.20 | Offline open of cached | Known cached item still opens | ☐ | ☐ | ☐ |  |

---

## Phase 5 — Collections (albums, trash, memories, map)

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 5.1 | Phone folders listed | Matches device albums/buckets | ☐ | ☐ | ☐ |  |
| 5.2 | Lelvo albums listed | Library albums appear | ☐ | ☐ | ☐ |  |
| 5.3 | Create album + add items | Notes / Telegram consistent | ☐ | ☐ | ☐ |  |
| 5.4 | Remove from album | Item leaves album, not library | ☐ | ☐ | ☐ |  |
| 5.5 | Delete album | Album gone; items remain | ☐ | ☐ | ☐ |  |
| 5.6 | Favorites smart row | Opens hearted set | ☐ | ☐ | ☐ |  |
| 5.7 | Videos / media-type rows | Correct filters | ☐ | ☐ | ☐ |  |
| 5.8 | Recent days | Sensible grouping | ☐ | ☐ | ☐ |  |
| 5.9 | Recently Deleted — recover | Item returns | ☐ | ☐ | ☐ |  |
| 5.10 | Recently Deleted — delete now | Gone for good after confirm | ☐ | ☐ | ☐ |  |
| 5.11 | 30-day cleanup | Item past retention removed (debug retention OK) | ☐ | ☐ | ☐ |  |
| 5.12 | Memories cards | On this day / recent / trips | ☐ | ☐ | ☐ |  |
| 5.13 | Memories story player | Plays; dismiss (X / swipe) clears cover | ☐ | ☐ | ☐ |  |
| 5.14 | Memories settings | Toggles stick after relaunch | ☐ | ☐ | ☐ |  |
| 5.15 | Map with places | Pins/clusters; tap → items | ☐ | ☐ | ☐ |  |
| 5.16 | Map light + dark | Readable both | ☐ | ☐ | ☐ |  |
| 5.17 | Item without GPS | Does not fake a place | ☐ | ☐ | ☐ |  |

---

## Phase 6 — Search

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 6.1 | Search by file name | Known name hits | ☐ | ☐ | ☐ |  |
| 6.2 | Search by date / month | Chips or typed date | ☐ | ☐ | ☐ |  |
| 6.3 | Search by place | City / place string | ☐ | ☐ | ☐ |  |
| 6.4 | Search by album | Album name | ☐ | ☐ | ☐ |  |
| 6.5 | Suggestions chips | Recent, places, Try… | ☐ | ☐ | ☐ |  |
| 6.6 | On-device labels (phone photos) | Label a few local photos; search “dog”/etc. | ☐ | ☐ | ☐ |  |
| 6.7 | No indexing of Telegram-sourced media for ML | Confirm cloud-only not labelled for upload/ML (terms) | ☐ | ☐ | ☐ |  |
| 6.8 | Empty results | Clear empty state | ☐ | ☐ | ☐ |  |
| 6.9 | Clear query | Returns to suggestions | ☐ | ☐ | ☐ |  |

---

## Phase 7 — Backup engine (deep)

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 7.1 | Back up now | Progress, lanes, ETA sensible | ☐ | ☐ | ☐ |  |
| 7.2 | Pause / resume | Pause holds; resume continues | ☐ | ☐ | ☐ |  |
| 7.3 | Retry failed | Force a fail (airplane) → Retry | ☐ | ☐ | ☐ |  |
| 7.4 | At most two parallel uploads | Watch concurrent jobs | ☐ | ☐ | ☐ |  |
| 7.5 | FLOOD_WAIT honoured | If hit, waits exact seconds, then continues | ☐ | ☐ | ☐ |  |
| 7.6 | Thumbnail (`t`) written | Every item has thumb role | ☐ | ☐ | ☐ |  |
| 7.7 | Screen copy (`d`) for large photo | Big JPEG gets display copy | ☐ | ☐ | ☐ |  |
| 7.8 | Fast video version | Created at backup or “Make fast version” | ☐ | ☐ | ☐ |  |
| 7.9 | Split large video | ≥2 GB or over part limit → multi-part; re-scan complete | ☐ | ☐ | ☐ |  |
| 7.10 | HEIC / JPEG / PNG / GIF | One of each backs up and opens | ☐ | ☐ | ☐ |  |
| 7.11 | Live Photo pair (iOS) | Photo + video motion preserved | ☐ | — | ☐ |  |
| 7.12 | Motion Photo (Android) | Single JPEG with embedded video | — | ☐ | — |  |
| 7.13 | Edited phone photo | Original bytes as platform stores them | ☐ | ☐ | ☐ |  |
| 7.14 | Keep screen on while backing up | Toggle works | ☐ | ☐ | ☐ |  |
| 7.15 | Dashboard counts | Waiting / done / failed match reality | ☐ | ☐ | ☐ |  |
| 7.16 | Failed → delete from phone row | Only after understanding risk | ☐ | ☐ | ☐ |  |
| 7.17 | Extra copies in Telegram | Deduplicator finds extras if present | ☐ | ☐ | ☐ |  |
| 7.18 | Removed from backup list | Accurate; re-backup possible | ☐ | ☐ | ☐ |  |
| 7.19 | Identical phone copies | Handled without double-upload chaos | ☐ | ☐ | ☐ |  |
| 7.20 | Wi‑Fi only setting | On cellular, waits with reason | ☐ | ☐ | ☐ |  |
| 7.21 | While charging setting | Unplugged waits if required | ☐ | ☐ | ☐ |  |
| 7.22 | Limited Photos access banner | Clear CTA when limited | ☐ | ☐ | ☐ |  |
| 7.23 | Demo backup (review) | Simulated 6 items; no real network needed | ☐ | ☐ | ☐ |  |
| 7.24 | Tools section | Each tool opens without crash | ☐ | ☐ | ☐ |  |

---

## Phase 8 — Free Up Space, restore, second copy

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 8.1 | Free Up lists only verified | Items not fully backed up absent | ☐ | ☐ | ☐ |  |
| 8.2 | Re-check right before delete | Telegram check immediately before system prompt | ☐ | ☐ | ☐ |  |
| 8.3 | Cancel system delete | Nothing removed | ☐ | ☐ | ☐ |  |
| 8.4 | Confirm delete | Phone gone; still in library | ☐ | ☐ | ☐ |  |
| 8.5 | Free Up after airplane | Does not claim verified offline | ☐ | ☐ | ☐ |  |
| 8.6 | Save everything to phone | Cloud-only set → Photos with date/place | ☐ | ☐ | ☐ |  |
| 8.7 | Save single item | From viewer | ☐ | ☐ | ☐ |  |
| 8.8 | Download a copy | File usable outside app | ☐ | ☐ | ☐ |  |
| 8.9 | Second copy to folder | Pick folder; files land; resume if interrupted | ☐ | ☐ | ☐ |  |
| 8.10 | Low device storage | Clear message; no corrupt half-files claimed done | ☐ | ☐ | ☐ |  |

---

## Phase 9 — Background and automation

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 9.1 | Automatic backup of new photo | Take photo; wait; uploads without opening Backup tab | ☐ | ☐ | ☐ |  |
| 9.2 | Cold start background | Force-quit; new photo; background still eventually runs | ☐ | ☐ | ☐ |  |
| 9.3 | Foreground progress notification (Android) | Pause from notification; finished notice | — | ☐ | — |  |
| 9.4 | iOS BG processing / continued | User-started long backup continues reasonably | ☐ | — | — |  |
| 9.5 | No silent-audio keep-alive | Confirm no fake audio / location tricks | ☐ | ☐ | ☐ |  |
| 9.6 | App shortcut: Back up now | Long-press icon / shortcuts | ☐ | ☐ | ☐ |  |
| 9.7 | App shortcut: Free up space | Opens flow | ☐ | ☐ | ☐ |  |
| 9.8 | Quick Settings tile (Android) | Status text; start/pause | — | ☐ | — |  |
| 9.9 | Automation guide (iOS) | Instructions accurate | ☐ | — | — |  |

---

## Phase 10 — Settings and account hygiene

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 10.1 | Signed-in identity shown | Number redacted sensibly in UI | ☐ | ☐ | ☐ |  |
| 10.2 | Library name / encryption status | Correct | ☐ | ☐ | ☐ |  |
| 10.3 | Change passphrase | Old fails; new unlocks; recovery key still works if unchanged | ☐ | ☐ | ☐ |  |
| 10.4 | View / confirm recovery key again | Path exists; no leak into logs | ☐ | ☐ | ☐ |  |
| 10.5 | Backup option toggles | Persist across relaunch | ☐ | ☐ | ☐ |  |
| 10.6 | Storage / cache clear | Clears cache; library intact | ☐ | ☐ | ☐ |  |
| 10.7 | Telegram account kept 2 years | Row / action behaves | ☐ | ☐ | ☐ |  |
| 10.8 | Share logs | Redacted; no phone, codes, keys, file ids | ☐ | ☐ | ☐ |  |
| 10.9 | Clear logs | Empties | ☐ | ☐ | ☐ |  |
| 10.10 | Report a problem | Mail / GitHub intent | ☐ | ☐ | ☐ |  |
| 10.11 | Suggest a feature | Same | ☐ | ☐ | ☐ |  |
| 10.12 | Privacy policy / FAQ / source / licences | Links open | ☐ | ☐ | ☐ |  |
| 10.13 | About version | Matches store build | ☐ | ☐ | ☐ |  |
| 10.14 | Light / dark / system | All main tabs | ☐ | ☐ | ☐ |  |
| 10.15 | Dynamic Type largest (iOS) | No clipped critical buttons | ☐ | — | — |  |
| 10.16 | VoiceOver / TalkBack basics | Tabs, Back up, viewer close labelled | ☐ | ☐ | ☐ |  |

---

## Phase 11 — Sync between devices

Do these with **iPhone + Android** (and Mac if ready) on the **same** library when allowed.

| # | Scenario | How to test | Pass | Notes |
|---|---|---|---|---|
| 11.1 | Favorite on A → appears on B after scan/sync | | ☐ |  |
| 11.2 | Album add on A → on B | | ☐ |  |
| 11.3 | Delete to Recently Deleted on A → on B | | ☐ |  |
| 11.4 | Recover on B → gone from trash on A | | ☐ |  |
| 11.5 | Phone favorite sync (platform favorite flag) | | ☐ |  |
| 11.6 | Live updates while both open | Backup on A while B open → B updates | ☐ |  |
| 11.7 | 10 s pacing / no flood on meta notes | | ☐ |  |
| 11.8 | Same photo on both phones → one library copy | | ☐ |  |

---

## Phase 12 — Similar photos and cleanup tools

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 12.1 | Similar / burst groups | Real burst set | ☐ | ☐ | ☐ |  |
| 12.2 | Pick Best | Marks best | ☐ | ☐ | ☐ |  |
| 12.3 | Delete extras on phone | Confirms | ☐ | ☐ | ☐ |  |
| 12.4 | Delete extras from backup | Confirms; Telegram cleaned | ☐ | ☐ | ☐ |  |
| 12.5 | No false merges of different people/scenes | Spot-check | ☐ | ☐ | ☐ |  |

---

## Phase 13 — World-class polish (S3)

Treat as a **quality bar**, not a shipping blocker for v1 — but tick before calling the app “finished”.

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 13.1 | First-run feels calm | No jargon; short sentences; no “!” | ☐ | ☐ | ☐ |  |
| 13.2 | Every empty state has one next action | | ☐ | ☐ | ☐ |  |
| 13.3 | Every error says what to do next | LocalizedError style | ☐ | ☐ | ☐ |  |
| 13.4 | Loading never looks stuck > few seconds without progress | | ☐ | ☐ | ☐ |  |
| 13.5 | Haptics only where helpful (iOS) | | ☐ | — | — |  |
| 13.6 | Transitions match system apps | Photos-like, not flashy | ☐ | ☐ | ☐ |  |
| 13.7 | No placeholder / TODO / beta strings | Search + tap every button | ☐ | ☐ | ☐ |  |
| 13.8 | Demo banner never confusable with real library | | ☐ | ☐ | ☐ |  |
| 13.9 | Grid doesn’t jump under thumb | | ☐ | ☐ | ☐ |  |
| 13.10 | Viewer chrome auto-hides sensibly | | ☐ | ☐ | ☐ |  |
| 13.11 | Backup tab readable at a glance | Counts + one primary CTA | ☐ | ☐ | ☐ |  |
| 13.12 | Kill app on every main screen | No crash on resume | ☐ | ☐ | ☐ |  |
| 13.13 | Rotate / fold / multi-window if claimed | | ☐ | ☐ | ☐ |  |
| 13.14 | iPad compatibility mode (iPhone app) | No crash | ☐ | — | — |  |
| 13.15 | Brand colours from tokens | Accent / status colours match design | ☐ | ☐ | ☐ |  |

---

## Phase 14 — Store, network, compliance

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 14.1 | Release build has no debug hooks | No UITest flags / demo shortcuts beyond intended review path | ☐ | ☐ | ☐ |  |
| 14.2 | Airplane → online | Clear state; resume | ☐ | ☐ | ☐ |  |
| 14.3 | IPv6-only (NAT64) | Demo works; real sign-in like official Telegram | ☐ | ☐ | ☐ |  |
| 14.4 | Oldest supported OS | Install + Phase 1 smoke | ☐ | ☐ | ☐ |  |
| 14.5 | Newest OS | Same | ☐ | ☐ | ☐ |  |
| 14.6 | Privacy labels / Data safety match PRIVACY.md | | ☐ | ☐ | ☐ |  |
| 14.7 | Listing discloses Telegram API | No Telegram logo/branding misuse | ☐ | ☐ | ☐ |  |
| 14.8 | No “unlimited / never lose / free storage” claims | Copy review | ☐ | ☐ | ☐ |  |
| 14.9 | Screenshots match build | | ☐ | ☐ | ☐ |  |
| 14.10 | Review notes + demo video (iOS) | Sign-in path documented | ☐ | — | ☐ |  |
| 14.11 | Play internal track install | Signed release APK/AAB | — | ☐ | — |  |
| 14.12 | Export compliance / encryption answers | Store forms | ☐ | ☐ | ☐ |  |

Full store paperwork: [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md).

---

## Phase 15 — Cross-platform gate

**Android may write to the real library only after this is green.**

| # | Scenario | How to test | Pass | Notes |
|---|---|---|---|---|
| 15.1 | iPhone → Android: photo opens, SHA / size match caption | | ☐ |  |
| 15.2 | iPhone → Android: video streams and plays | | ☐ |  |
| 15.3 | iPhone → Android: Live Photo behaviour | | ☐ |  |
| 15.4 | Android → iPhone: photo / Motion / video | | ☐ |  |
| 15.5 | Split large video both ways | | ☐ |  |
| 15.6 | Interrupted upload both ways → complete, no dup | | ☐ |  |
| 15.7 | Save to phone both ways usable | | ☐ |  |
| 15.8 | Favorites / albums / trash notes both ways | | ☐ |  |
| 15.9 | Parity audit written (every iOS feature mapped or justified) | | ☐ |  |
| 15.10 | Android 10 / 13 / 14 / 15 / 16 smoke of Phase 1 | | ☐ |  |
| 15.11 | Mac open same library (if shipping Mac) | | ☐ |  |
| 15.12 | Privacy policy mentions Android | | ☐ |  |

---

## Phase 16 — Pro (worth paying)

**Status (2026-11-15):** Tier A is **implemented** on iOS, Mac and Android (Apple: StoreKit + debug unlock; Android: debug unlock, Play Billing later). Use Mon/Tue smoke before charging anyone.

Rules from strategy (do not violate in tests or UX):

- Backup, restore, encryption, Save to Photos, Download a copy, Free Up Space, Takeout stay **Free forever**.
- Pro = convenience / intelligence / polish — **never** access to your own library.
- Never promise more Telegram storage or faster uploads than Telegram allows.
- On-device ML only on the phone’s own Photos (before upload), never on Telegram-sourced media.

### Why Pro feels worth it (product bar, not just “feature exists”)

People pay at **pain or delight**, not at a feature list. Test that each paid surface:

1. **Appears at the moment of need** (open Locked Folder, run Smart Cleanup, hit Search with no results) — not a wall of twelve bullets in Settings.
2. **Shows a concrete outcome** (“Free ~4.2 GB”, “12 private items”, “Results for beach”) before asking for money.
3. **Trial / restore / redeem work** — paying must feel safer than Free, never riskier.
4. **Free path never feels crippled** — after dismissing paywall, core backup still works.

Recommended wedge order (strategy): **Locked folder** or **Smart cleanup** first → **Smart search** → Memories polish → Mac folder backup → Tier B.

### Mon/Tue smoke (do these first)

| # | Scenario | iOS | And | Mac | Notes |
|---|---|---|---|---|---|
| M.1 | Debug unlock Pro → Locked / Cleanup / Search things / Themes unlock | ☐ | ☐ | ☐ |  |
| M.2 | Turn Pro off → gold **PRO** + paywall / unlock row | ☐ | ☐ | ☐ |  |
| M.3 | Free: backup, restore, Free Up, encryption still work | ☐ | ☐ | ☐ |  |
| M.4 | Lock one backed-up photo on phone → open Locked on Mac (and Android) → same photo | ☐ | ☐ | ☐ |  |
| M.5 | Smart Cleanup: estimate while Free; delete only after Pro + confirm | ☐ | ☐ | ☐ |  |
| M.6 | Search a “thing” label: Free → Pro gate; Pro → results | ☐ | ☐ | ☐ |  |

### 16A — Billing & entitlement

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 16A.1 | Paywall copy is short and honest | No storage/speed lies | ☐ | ☐ | ☐ |  |
| 16A.2 | Start yearly trial | Store sheet; entitlement unlocks | ☐ | — | ☐ |  |
| 16A.3 | Buy monthly | Unlock | ☐ | — | ☐ |  |
| 16A.4 | Buy lifetime (if offered) | Unlock; survives relaunch | ☐ | — | ☐ |  |
| 16A.5 | Cancel mid-sheet | Stays Free; no half-state | ☐ | ☐ | ☐ |  |
| 16A.6 | Restore Purchases | New install / second device same store account | ☐ | — | ☐ |  |
| 16A.7 | Redeem offer / founder code | App Store Connect offer codes → system Redeem sheet | ☐ | — | ☐ |  |
| 16A.8 | Expired trial → Free | Pro features lock; Free core intact | ☐ | — | ☐ |  |
| 16A.9 | Debug unlock never in release | Release build: no Debug toggle | ☐ | ☐ | ☐ |  |
| 16A.10 | Family Sharing / Play family (when shipped) | Member gets Pro as designed | ☐ | ☐ | ☐ |  |
| 16A.11 | Offline with valid entitlement | Pro still works | ☐ | ☐ | ☐ |  |
| 16A.12 | Free user never blocked from backup/restore/encryption/Free Up | Explicit regression | ☐ | ☐ | ☐ |  |

### 16B — Locked folder (Tier A)

MetaLog: caption `CGM1:` / `CGM1E:`, ops `lock` / `unlock` (same family as favorites/albums). Does **not** move photo files.

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 16B.1 | Free user hits Face ID / lock gate → paywall | | ☐ | ☐ | ☐ |  |
| 16B.2 | Pro: Face ID / passcode / phone lock / Touch ID | Mac: Touch ID or login password | ☐ | ☐ | ☐ |  |
| 16B.3 | Hide items into locked folder | Gone from main timeline, search, memories | ☐ | ☐ | ☐ |  |
| 16B.4 | Unlock → items visible | | ☐ | ☐ | ☐ |  |
| 16B.5 | App background → re-lock (grace) + app-switcher blur | | ☐ | ☐ | ☐ |  |
| 16B.6 | Wrong auth → no peek | | ☐ | ☐ | ☐ |  |
| 16B.7 | Move out of locked folder | Timeline restore; Telegram media unchanged | ☐ | ☐ | ☐ |  |
| 16B.8 | Backup still includes locked items | Bytes stay in channel; Free Up excludes locked | ☐ | ☐ | ☐ |  |
| 16B.9 | Recovery if biometrics change | Device passcode fallback | ☐ | ☐ | ☐ |  |
| 16B.10 | Feels private like Google’s Locked Folder | Side-by-side UX check | ☐ | ☐ | ☐ |  |
| 16B.11 | Two devices same library | Lock on A → open Locked on B; hidden on B | ☐ | ☐ | ☐ |  |
| 16B.12 | Unlock on B | Appears on A after sync | ☐ | ☐ | ☐ |  |
| 16B.13 | Airplane then sync | Pending lock note sends when online | ☐ | ☐ | ☐ |  |
| 16B.14 | Phone-only then backup | Pending hide → lock note after backup | ☐ | ☐ | ☐ |  |
| 16B.15 | E2E vs plain honesty | Copy says Telegram may still list files unless E2E | ☐ | ☐ | ☐ |  |
| 16B.16 | Gold **PRO** on Locked entry / toolbar | | ☐ | ☐ | ☐ |  |
| 16B.17 | Mac empty but phone has item | Unlock+lock again on phone so the note sends; reopen Locked on Mac | ☐ | ☐ | ☐ |  |

### 16C — Smart cleanup (Tier A)

Exact Telegram/phone duplicates stay **Free**. Similar / screenshots / large videos (+ blurry on Apple when scored) are **Pro**. Estimate before pay.

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 16C.1 | Free Up Space still Free | No paywall on classic Free Up | ☐ | ☐ | ☐ |  |
| 16C.2 | Smart cleanup entry → paywall for Free | Gold **PRO** on entry | ☐ | ☐ | ☐ |  |
| 16C.3 | Groups: similar, screenshots, large videos (+ blurry Apple) | | ☐ | ☐ | ☐ |  |
| 16C.4 | Shows estimated space freed **before** pay | | ☐ | ☐ | ☐ |  |
| 16C.5 | Pro: select extras → delete phone / backup safely | | ☐ | ☐ | ☐ |  |
| 16C.6 | Never deletes without confirm | | ☐ | ☐ | ☐ |  |
| 16C.7 | Feels smarter than plain Free Up | User would pay test | ☐ | ☐ | ☐ |  |

### 16D — Smart search (Tier A)

Free: places, dates, kinds, filenames/albums. Pro: things in the photo. OCR text-in-photo is Apple-only for now.

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 16D.1 | Basic name/date/place search stays Free | | ☐ | ☐ | ☐ |  |
| 16D.2 | Visual / “beach” / things → Pro gate at need | | ☐ | ☐ | ☐ |  |
| 16D.3 | Results feel Google-Photos-good on phone library | | ☐ | ☐ | ☐ |  |
| 16D.4 | ML only on local Photos; not Telegram downloads | | ☐ | ☐ | ☐ |  |
| 16D.5 | Indexing progress clear; battery OK | | ☐ | ☐ | ☐ |  |
| 16D.6 | Gold **PRO** on Smart Search teaser when Free | | ☐ | ☐ | ☐ |  |

### 16E — Memories polish & desktop folder (Tier A)

| # | Scenario | How to test | iOS | And | Mac | Notes |
|---|---|---|---|---|---|---|
| 16E.1 | Base Memories stay Free (on this day / recent / trips) | | ☐ | ☐ | ☐ |  |
| 16E.2 | Themes gated Pro; gold **PRO** on Themes when Free | | ☐ | ☐ | ☐ |  |
| 16E.3 | Folder / second copy Pro; viewer/restore Free | | ☐ | ☐ | ☐ |  |
| 16E.4 | Folder watch / SD / Downloads / SAF path | | — | ☐ | ☐ |  |

### 16F — Tier B (when built)

| # | Scenario | How to test | Pass | Notes |
|---|---|---|---|---|
| 16F.1 | Free: one library; Pro: more libraries | | ☐ |  |
| 16F.2 | Family plan seats | | ☐ |  |
| 16F.3 | Streaming / fast copies extras | | ☐ |  |
| 16F.4 | Advanced map / stats | | ☐ |  |
| 16F.5 | Widgets / icons / themes | | ☐ |  |
| 16F.6 | Priority support path (process, not magic) | | ☐ |  |

### 16G — Pro “would I pay?” review (human)

Run once per Pro wedge with a cold user or yourself after 24 hours away:

| # | Question | Yes | Notes |
|---|---|---|---|
| 16G.1 | Did I hit the paywall at a moment of real need? | ☐ |  |
| 16G.2 | Did I see a concrete benefit before Apple/Google sheet? | ☐ |  |
| 16G.3 | Is Free still a complete backup app I’m proud of? | ☐ |  |
| 16G.4 | Would I pay yearly at the listed price for this one feature alone? | ☐ |  |
| 16G.5 | Would I be embarrassed if a reviewer compared us to Google Photos Locked Folder / search? | ☐ (want No) |  |

If 16G.4 is No for the first wedge, **do not ship billing yet** — polish that wedge.

---

## Suggested schedule

Every day starts with Phase 0. Stability phases first; Pro waits.

| Day | Focus |
|---|---|
| 1 | Phase 1 on iPhone, Android, Mac |
| 2 | Phase T (start the T.12 long run in the morning) + Phase C |
| 3 | Phase D + Phase L |
| 4 | Phase P (40k library) + Phase 7 |
| 5 | Phases 2–4 |
| 6 | Phases 5, 6, 8 |
| 7 | Phases 9–11 + Phase M |
| 8 | Phases 12–15; Android real-library decision |
| Later | Phase 16 Pro — only after the owner says stability is done |

---

## Appendix A — Mac

Moved into the main plan: Mac runs every row that applies, plus Phase M.

---

## Appendix B — Import / Takeout (Free forever)

| # | Scenario | Pass | Notes |
|---|---|---|---|
| B.1 | Google Takeout import path completes without paywall | ☐ |  |
| B.2 | Drive import if shipped | ☐ |  |
| B.3 | Failures explain next step; no silent skips | ☐ |  |

---

## Appendix B2 — Takeout import edge cases (iPhone shipped, Android next)

| # | Scenario | iOS | And | Notes |
|---|---|---|---|---|
| B.4 | Multi-part Takeout (several .zip files) | ☐ | ☐ |  |
| B.5 | Sidecar JSON dates and places win over file dates | ☐ | ☐ |  |
| B.6 | Photos already in the library are not uploaded twice | ☐ | ☐ |  |
| B.7 | Kill mid-import → resumes where it stopped | ☐ | ☐ |  |
| B.8 | Zip bigger than free phone space | ☐ | ☐ |  |
| B.9 | Non-English Takeout folder names | ☐ | ☐ |  |

---

## Appendix D — What Claude can automate (so you test less by hand)

Ask for any line by its id. Each one is a separate small PR; nothing here changes the storage format.

| Id | Tool | Replaces / speeds up | Effort |
|---|---|---|---|
| A1 | `Scripts/check-log.sh <log>`: flags phone numbers, codes, 64-hex keys, file ids; checks every FLOOD_WAIT was waited in full; counts parallel uploads; lists errors by kind | 10.8, T.1, T.2, T.3, 7.4, 7.5 | small |
| A2 | Debug-only fault injection launch args (`#if DEBUG`): fake FLOOD_WAIT of N s, fail upload at part K, drop network, slow network, disk full | T.1, 1.10, 1.11, 7.3, 7.5, L.4, L.6 — makes them repeatable in seconds instead of luck | medium |
| A3 | Debug "Check library" action: for every index row, compare caption parts and sizes with Telegram, list items "backed up" but incomplete, and junk messages | 1.12, 1.22, T.7, T.8, C.2 | medium |
| A4 | Seed a 40k library: `xcrun simctl addmedia` for the simulator, `adb push` + media scan for the emulator, from generated images and short videos (dates spread over 10 years, some with GPS) | Phase P, C.1, 3.21 | small |
| A5 | Media zoo: one file of every kind in Phase D generated or collected into a folder, pushed to simulator/emulator | Phase D (except iCloud rows) | small |
| A6 | Round-trip test: back up in demo/test library → restore → compare SHA-256 | 1.19, 15.1 | medium |
| A7 | Cross-platform vector test — **already exists** (Swift `FormatTests`, Kotlin `VectorsTest`); extend only if a new format field ships | 1.16, 1.17, 15.x | done |
| A8 | Upgrade test: install previous release build, seed data, install RC over it, check library opens and queue survives (simulator + emulator) | 1.15, 1.17 | medium |
| A9 | UI tests for counts: demo library with known numbers; assert Backup tab and grid totals after delete / recover | C.3–C.6 | small |
| A10 | Release binary check + copy lint (0.9, 0.10) | 14.1, 13.1, 13.7 | small |
| A11 | Performance tests: XCTest `measure` for launch and grid scroll on seeded library; Android Macrobenchmark | P.1–P.3, P.6 | medium |

Still by hand: real sign-in and 2FA, iCloud originals, Telegram session ending, @SpamBot check, battery, heat,
calls, App Store / Play paperwork, and anything that touches your real photos.

---

## Appendix C — Scorecard

| Phase | iOS | Android | Mac | Ship? | Notes |
|---|---|---|---|---|---|
| 0 Automated gate | ☐ | ☐ | ☐ | Must, every session |  |
| 1 Trust core | ☐ | ☐ | ☐ | Must |  |
| T Telegram safety | ☐ | ☐ | ☐ | Must |  |
| D Media edge cases | ☐ | ☐ | ☐ | Must |  |
| C Counts | ☐ | ☐ | ☐ | Must |  |
| L Interruptions | ☐ | ☐ | ☐ | Must |  |
| P Performance 40k | ☐ | ☐ | ☐ | Must |  |
| M Mac only | — | — | ☐ | Must |  |
| 2 Sign-in / library | ☐ | ☐ | ☐ | Must |  |
| 3 Gallery | ☐ | ☐ | ☐ | Must |  |
| 4 Viewer | ☐ | ☐ | ☐ | Must |  |
| 5 Collections | ☐ | ☐ | ☐ | Must for feature parity |  |
| 6 Search | ☐ | ☐ | ☐ | Must for feature parity |  |
| 7 Backup deep | ☐ | ☐ | ☐ | Must |  |
| 8 Free Up / restore | ☐ | ☐ | ☐ | Must |  |
| 9 Background | ☐ | ☐ | ☐ | Strongly before 1.0 |  |
| 10 Settings | ☐ | ☐ | ☐ | Must |  |
| 11 Cross-device sync | ☐ | ☐ | ☐ | Must before dual-store story |  |
| 12 Similar | ☐ | ☐ | ☐ | If shipped |  |
| 13 Polish | ☐ | ☐ | ☐ | World-class bar |  |
| 14 Store | ☐ | ☐ | ☐ | Must |  |
| 15 Gate N | ☐ | ☐ | ☐ | Must before Android real writes |  |
| 16 Pro | ☐ | ☐ | — | Before charging |  |

---

## Opinion (keep product honest)

World-class here means **trust first**: false “backed up” or a bad Free Up is worse than a missing Memories polish.
Pro should feel like Google Photos intelligence **on storage you already own** — Locked Folder and Smart Cleanup
that show “private” or “GB freed” at the moment of need. If Free is incomplete, Pro feels like a ransom; if Free is
excellent and Pro is clearly smarter, people pay.

Update this file when a feature ships or a hard Free/Pro rule changes. Date the change in the commit message.
