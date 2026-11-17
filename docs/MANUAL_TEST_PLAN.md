# Manual test plan — Free (Phase 1→N) and Pro

Hand checklist for shipping a world-class Lelvo on **iPhone** and **Android** (Mac notes in the appendix).
Use this before App Store / Play release, after big backup or crypto changes, and when Pro ships.

Related: [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md) (store paperwork), [ANDROID_PLAN.md](ANDROID_PLAN.md)
(Android build order and write-safety), `marketing/PRO_STRATEGY.md` (Free vs Pro rules — not in git).

---

## How to use this

1. **One scenario at a time.** Tick the box only after you saw it pass on that device.
2. **Same build** you will ship (TestFlight / internal track / release candidate). Demo mode alone is not enough.
3. **Log failures** as: phase · scenario · device · OS · what you did · what happened · expected.
4. **Android write safety:** until Phase N (cross-platform gate) is green, backups / deletes / notes go to an
   **"Android test"** library only. Reading the real library is fine.
5. **Never test Free Up Space** on irreplaceable photos. Use disposable shots you have verified in Telegram.

### Severity (what blocks release)

| Level | Meaning | Examples |
|---|---|---|
| **S0 — Block ship** | Data loss, false “backed up”, lockout, silent delete | Incomplete upload marked done; Free Up deletes without confirm; recovery key unlock fails |
| **S1 — Block this platform** | Core flow broken on one OS | Sign-in stuck; viewer black for all cloud items; resume after kill duplicates everything |
| **S2 — Fix before wide users** | Trust or money path broken | Paywall traps Free; Restore Purchases fails; cross-device note sync wrong |
| **S3 — Polish** | World-class bar, not day-one trust | Scrubber hitch, dark-mode tint, empty-state wording |

**Ship bar:** all S0 must be green on both phones. S1 green on that platform. S2 green before Pro ads.
S3 you can schedule — but a “world-class” claim means you keep burning them down.

### Devices (fill in)

| Device | OS | Build | Role |
|---|---|---|---|
| iPhone | | | Primary Free + App Review path |
| Android phone | | | Primary Free + Play internal |
| Second phone / emulator | | | Cross-device / older OS |
| Mac (optional) | | | Viewer / restore / folder backup later |

Columns in checklists: **iOS** · **And** · Pass notes.

---

## Phase 1 — Trust core (never lose a photo)

Goal: nobody can lose photos or be lied to about backup. If anything here fails, stop.

| # | Scenario | How to test | Breaks if… | iOS | And |
|---|---|---|---|---|---|
| 1.1 | Fresh install launches | Delete app → install RC → open light + dark | Crash, blank, wrong “signed in” | ☐ | ☐ |
| 1.2 | Real Telegram sign-in | Number → code → 2FA → home | Stuck spinner, wrong errors, no session | ☐ | ☐ |
| 1.3 | Session survives kill | Force-quit → reopen within a minute | Asks for code again every time | ☐ | ☐ |
| 1.4 | Open / create encrypted library | Create or unlock; write recovery key on paper; confirm | Key skipped; unlock with wrong key; crash | ☐ | ☐ |
| 1.5 | Recovery key after reinstall | Reinstall → sign in → unlock with recovery key only | Lockout; treats fail as “no library” | ☐ | ☐ |
| 1.6 | Photos permission: denied | Deny → still open cloud library | Trapped behind permission wall | ☐ | ☐ |
| 1.7 | Photos permission: limited / partial | Select few photos → Backup + grid behave | Crash; backs up without access | ☐ | ☐ |
| 1.8 | Photos permission: full | Grant → phone items appear | Empty forever | ☐ | ☐ |
| 1.9 | Small real backup | 1 photo + 1 Live/Motion + 1 short video → Back up now → check Telegram + re-scan | Marked done incomplete; missing parts | ☐ | ☐ |
| 1.10 | Kill mid-backup | Kill at ~50% → reopen → resume | Duplicates; stuck; false complete | ☐ | ☐ |
| 1.11 | Airplane mid-backup | Airplane → online → resume | Crash; silent success; endless hang | ☐ | ☐ |
| 1.12 | “Backed up” only when confirmed | Compare channel file sizes / parts to caption | UI green while Telegram incomplete | ☐ | ☐ |
| 1.13 | Free Up Space — one disposable | Verify in Telegram → Free Up → cancel once → confirm once | Deletes without confirm; deletes non-backed-up | ☐ | ☐ |
| 1.14 | Sign out and reset | Sign out → data gone → sign in → unlock → library intact in Telegram | Half-cleared session; library wiped | ☐ | ☐ |

**Phase 1 pass:** every row green on the platform you are shipping.

---

## Phase 2 — Sign-in, onboarding, library edge cases

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 2.1 | Intro pages readable, skippable | Walk all intro pages; back/forward | ☐ | ☐ |
| 2.2 | Wrong login code | Enter bad code → clear message, retry | ☐ | ☐ |
| 2.3 | Resend code | Wait / tap resend; labels match delivery | ☐ | ☐ |
| 2.4 | Wrong 2FA password | Clear error; no lockout spam | ☐ | ☐ |
| 2.5 | No Telegram account | Number with no account → points to Telegram | ☐ | ☐ |
| 2.6 | Session ended elsewhere | Sign in on second client that ends sessions if available | ☐ | ☐ |
| 2.7 | Demo / App Review login (iOS) | Review number + code → sample library; Back up now simulates | ☐ | — |
| 2.8 | Choose among multiple libraries | If several channels exist, pick correct one | ☐ | ☐ |
| 2.9 | Wrong passphrase | Refuse; no wipe | ☐ | ☐ |
| 2.10 | Damaged / newer / plain header | Open incompatible library → “incompatible”, never “repair” | ☐ | ☐ |
| 2.11 | New library shows recovery key once | Must confirm; cannot skip | ☐ | ☐ |
| 2.12 | Library ready / Welcome back counts | First scan and return visit show sensible counts | ☐ | ☐ |
| 2.13 | Switch library | Switch → index matches that channel | ☐ | ☐ |
| 2.14 | Rename library (if offered) | Name updates in Settings and Telegram | ☐ | ☐ |

---

## Phase 3 — Gallery timeline

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 3.1 | Phone + cloud in one timeline | Mix of local and backed-up; scroll | ☐ | ☐ |
| 3.2 | Day / month / year grouping | Pinch or zoom levels if available | ☐ | ☐ |
| 3.3 | Date scrubber | Fast scroll; date label correct | ☐ | ☐ |
| 3.4 | Status badges | Backed up / waiting / attention colours match legend | ☐ | ☐ |
| 3.5 | “What the icons mean” | Open help / legend sheet | ☐ | ☐ |
| 3.6 | Filter: videos | Only videos | ☐ | ☐ |
| 3.7 | Filter: Live / Motion | Only those kinds | ☐ | ☐ |
| 3.8 | Filter: favorites | Hearted only | ☐ | ☐ |
| 3.9 | Filter: only in Telegram | Cloud-only visible | ☐ | ☐ |
| 3.10 | Filter: not backed up | Waiting / local-only | ☐ | ☐ |
| 3.11 | Select + swipe-select | Long-press, drag, edge auto-scroll | ☐ | ☐ |
| 3.12 | Select all in view | Selects expected set | ☐ | ☐ |
| 3.13 | Multi: back up | Selected upload | ☐ | ☐ |
| 3.14 | Multi: share | System share sheet | ☐ | ☐ |
| 3.15 | Multi: favorite | Phone and/or library heart | ☐ | ☐ |
| 3.16 | Multi: add to album | Existing + new album | ☐ | ☐ |
| 3.17 | Multi: delete phone | System confirm; only phone | ☐ | ☐ |
| 3.18 | Multi: delete backup only | Leaves phone; removes from library | ☐ | ☐ |
| 3.19 | Multi: delete everywhere | Both sides with confirms | ☐ | ☐ |
| 3.20 | New phone photo appears | Take a photo → appears without reinstall | ☐ | ☐ |
| 3.21 | Large library scroll | 1k+ items; no crash; usable FPS | ☐ | ☐ |
| 3.22 | Empty library | New account empty state is clear | ☐ | ☐ |
| 3.23 | Pull / re-scan | Re-scan does not wipe correct items | ☐ | ☐ |

---

## Phase 4 — Viewer (photo, Live/Motion, video)

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 4.1 | Swipe between items | Pager keeps place | ☐ | ☐ |
| 4.2 | Close gesture | Swipe down / back | ☐ | ☐ |
| 4.3 | Details sheet | Swipe up / info: date, place, camera, size, where | ☐ | ☐ |
| 4.4 | Zoom + double-tap | Sharp when zoomed | ☐ | ☐ |
| 4.5 | Screen copy then original | Soft then sharp load for cloud | ☐ | ☐ |
| 4.6 | Share original | Shared file opens elsewhere | ☐ | ☐ |
| 4.7 | Save to phone | Lands in Photos / gallery with date | ☐ | ☐ |
| 4.8 | Favorite from viewer | Syncs to grid | ☐ | ☐ |
| 4.9 | Delete from viewer | Phone / backup / everywhere paths | ☐ | ☐ |
| 4.10 | Live Photo play | Press / chip; paired motion | ☐ | — |
| 4.11 | Motion Photo play | Chip / long press | — | ☐ |
| 4.12 | Video play / pause | Starts without black forever | ☐ | ☐ |
| 4.13 | Scrub + frame strip | Seek lands near target | ☐ | ☐ |
| 4.14 | Mute / speed / ±10 s | Controls work; mute sticks as designed | ☐ | ☐ |
| 4.15 | Quality pill / fast version | Switch if present; stall fallback | ☐ | ☐ |
| 4.16 | Resume playback position | Leave mid-video (>2 min) → reopen near same time | ☐ | ☐ |
| 4.17 | Sound off on close | No audio after leaving viewer | ☐ | ☐ |
| 4.18 | Place opens Maps | Tap place → maps app | ☐ | ☐ |
| 4.19 | Neighbour prefetch on Wi‑Fi | Next items open faster | ☐ | ☐ |
| 4.20 | Offline open of cached | Known cached item still opens | ☐ | ☐ |

---

## Phase 5 — Collections (albums, trash, memories, map)

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 5.1 | Phone folders listed | Matches device albums/buckets | ☐ | ☐ |
| 5.2 | Lelvo albums listed | Library albums appear | ☐ | ☐ |
| 5.3 | Create album + add items | Notes / Telegram consistent | ☐ | ☐ |
| 5.4 | Remove from album | Item leaves album, not library | ☐ | ☐ |
| 5.5 | Delete album | Album gone; items remain | ☐ | ☐ |
| 5.6 | Favorites smart row | Opens hearted set | ☐ | ☐ |
| 5.7 | Videos / media-type rows | Correct filters | ☐ | ☐ |
| 5.8 | Recent days | Sensible grouping | ☐ | ☐ |
| 5.9 | Recently Deleted — recover | Item returns | ☐ | ☐ |
| 5.10 | Recently Deleted — delete now | Gone for good after confirm | ☐ | ☐ |
| 5.11 | 30-day cleanup | Item past retention removed (debug retention OK) | ☐ | ☐ |
| 5.12 | Memories cards | On this day / recent / trips | ☐ | ☐ |
| 5.13 | Memories story player | Plays; dismiss (X / swipe) clears cover | ☐ | ☐ |
| 5.14 | Memories settings | Toggles stick after relaunch | ☐ | ☐ |
| 5.15 | Map with places | Pins/clusters; tap → items | ☐ | ☐ |
| 5.16 | Map light + dark | Readable both | ☐ | ☐ |
| 5.17 | Item without GPS | Does not fake a place | ☐ | ☐ |

---

## Phase 6 — Search

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 6.1 | Search by file name | Known name hits | ☐ | ☐ |
| 6.2 | Search by date / month | Chips or typed date | ☐ | ☐ |
| 6.3 | Search by place | City / place string | ☐ | ☐ |
| 6.4 | Search by album | Album name | ☐ | ☐ |
| 6.5 | Suggestions chips | Recent, places, Try… | ☐ | ☐ |
| 6.6 | On-device labels (phone photos) | Label a few local photos; search “dog”/etc. | ☐ | ☐ |
| 6.7 | No indexing of Telegram-sourced media for ML | Confirm cloud-only not labelled for upload/ML (terms) | ☐ | ☐ |
| 6.8 | Empty results | Clear empty state | ☐ | ☐ |
| 6.9 | Clear query | Returns to suggestions | ☐ | ☐ |

---

## Phase 7 — Backup engine (deep)

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 7.1 | Back up now | Progress, lanes, ETA sensible | ☐ | ☐ |
| 7.2 | Pause / resume | Pause holds; resume continues | ☐ | ☐ |
| 7.3 | Retry failed | Force a fail (airplane) → Retry | ☐ | ☐ |
| 7.4 | At most two parallel uploads | Watch concurrent jobs | ☐ | ☐ |
| 7.5 | FLOOD_WAIT honoured | If hit, waits exact seconds, then continues | ☐ | ☐ |
| 7.6 | Thumbnail (`t`) written | Every item has thumb role | ☐ | ☐ |
| 7.7 | Screen copy (`d`) for large photo | Big JPEG gets display copy | ☐ | ☐ |
| 7.8 | Fast video version | Created at backup or “Make fast version” | ☐ | ☐ |
| 7.9 | Split large video | ≥2 GB or over part limit → multi-part; re-scan complete | ☐ | ☐ |
| 7.10 | HEIC / JPEG / PNG / GIF | One of each backs up and opens | ☐ | ☐ |
| 7.11 | Live Photo pair (iOS) | Photo + video motion preserved | ☐ | — |
| 7.12 | Motion Photo (Android) | Single JPEG with embedded video | — | ☐ |
| 7.13 | Edited phone photo | Original bytes as platform stores them | ☐ | ☐ |
| 7.14 | Keep screen on while backing up | Toggle works | ☐ | ☐ |
| 7.15 | Dashboard counts | Waiting / done / failed match reality | ☐ | ☐ |
| 7.16 | Failed → delete from phone row | Only after understanding risk | ☐ | ☐ |
| 7.17 | Extra copies in Telegram | Deduplicator finds extras if present | ☐ | ☐ |
| 7.18 | Removed from backup list | Accurate; re-backup possible | ☐ | ☐ |
| 7.19 | Identical phone copies | Handled without double-upload chaos | ☐ | ☐ |
| 7.20 | Wi‑Fi only setting | On cellular, waits with reason | ☐ | ☐ |
| 7.21 | While charging setting | Unplugged waits if required | ☐ | ☐ |
| 7.22 | Limited Photos access banner | Clear CTA when limited | ☐ | ☐ |
| 7.23 | Demo backup (review) | Simulated 6 items; no real network needed | ☐ | ☐ |
| 7.24 | Tools section | Each tool opens without crash | ☐ | ☐ |

---

## Phase 8 — Free Up Space, restore, second copy

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 8.1 | Free Up lists only verified | Items not fully backed up absent | ☐ | ☐ |
| 8.2 | Re-check right before delete | Telegram check immediately before system prompt | ☐ | ☐ |
| 8.3 | Cancel system delete | Nothing removed | ☐ | ☐ |
| 8.4 | Confirm delete | Phone gone; still in library | ☐ | ☐ |
| 8.5 | Free Up after airplane | Does not claim verified offline | ☐ | ☐ |
| 8.6 | Save everything to phone | Cloud-only set → Photos with date/place | ☐ | ☐ |
| 8.7 | Save single item | From viewer | ☐ | ☐ |
| 8.8 | Download a copy | File usable outside app | ☐ | ☐ |
| 8.9 | Second copy to folder | Pick folder; files land; resume if interrupted | ☐ | ☐ |
| 8.10 | Low device storage | Clear message; no corrupt half-files claimed done | ☐ | ☐ |

---

## Phase 9 — Background and automation

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 9.1 | Automatic backup of new photo | Take photo; wait; uploads without opening Backup tab | ☐ | ☐ |
| 9.2 | Cold start background | Force-quit; new photo; background still eventually runs | ☐ | ☐ |
| 9.3 | Foreground progress notification (Android) | Pause from notification; finished notice | — | ☐ |
| 9.4 | iOS BG processing / continued | User-started long backup continues reasonably | ☐ | — |
| 9.5 | No silent-audio keep-alive | Confirm no fake audio / location tricks | ☐ | ☐ |
| 9.6 | App shortcut: Back up now | Long-press icon / shortcuts | ☐ | ☐ |
| 9.7 | App shortcut: Free up space | Opens flow | ☐ | ☐ |
| 9.8 | Quick Settings tile (Android) | Status text; start/pause | — | ☐ |
| 9.9 | Automation guide (iOS) | Instructions accurate | ☐ | — |

---

## Phase 10 — Settings and account hygiene

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 10.1 | Signed-in identity shown | Number redacted sensibly in UI | ☐ | ☐ |
| 10.2 | Library name / encryption status | Correct | ☐ | ☐ |
| 10.3 | Change passphrase | Old fails; new unlocks; recovery key still works if unchanged | ☐ | ☐ |
| 10.4 | View / confirm recovery key again | Path exists; no leak into logs | ☐ | ☐ |
| 10.5 | Backup option toggles | Persist across relaunch | ☐ | ☐ |
| 10.6 | Storage / cache clear | Clears cache; library intact | ☐ | ☐ |
| 10.7 | Telegram account kept 2 years | Row / action behaves | ☐ | ☐ |
| 10.8 | Share logs | Redacted; no phone, codes, keys, file ids | ☐ | ☐ |
| 10.9 | Clear logs | Empties | ☐ | ☐ |
| 10.10 | Report a problem | Mail / GitHub intent | ☐ | ☐ |
| 10.11 | Suggest a feature | Same | ☐ | ☐ |
| 10.12 | Privacy policy / FAQ / source / licences | Links open | ☐ | ☐ |
| 10.13 | About version | Matches store build | ☐ | ☐ |
| 10.14 | Light / dark / system | All main tabs | ☐ | ☐ |
| 10.15 | Dynamic Type largest (iOS) | No clipped critical buttons | ☐ | — |
| 10.16 | VoiceOver / TalkBack basics | Tabs, Back up, viewer close labelled | ☐ | ☐ |

---

## Phase 11 — Sync between devices

Do these with **iPhone + Android** (and Mac if ready) on the **same** library when allowed.

| # | Scenario | How to test | Pass |
|---|---|---|---|
| 11.1 | Favorite on A → appears on B after scan/sync | ☐ |
| 11.2 | Album add on A → on B | ☐ |
| 11.3 | Delete to Recently Deleted on A → on B | ☐ |
| 11.4 | Recover on B → gone from trash on A | ☐ |
| 11.5 | Phone favorite sync (platform favorite flag) | ☐ |
| 11.6 | Live updates while both open | Backup on A while B open → B updates | ☐ |
| 11.7 | 10 s pacing / no flood on meta notes | ☐ |
| 11.8 | Same photo on both phones → one library copy | ☐ |

---

## Phase 12 — Similar photos and cleanup tools

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 12.1 | Similar / burst groups | Real burst set | ☐ | ☐ |
| 12.2 | Pick Best | Marks best | ☐ | ☐ |
| 12.3 | Delete extras on phone | Confirms | ☐ | ☐ |
| 12.4 | Delete extras from backup | Confirms; Telegram cleaned | ☐ | ☐ |
| 12.5 | No false merges of different people/scenes | Spot-check | ☐ | ☐ |

---

## Phase 13 — World-class polish (S3)

Treat as a **quality bar**, not a shipping blocker for v1 — but tick before calling the app “finished”.

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 13.1 | First-run feels calm | No jargon; short sentences; no “!” | ☐ | ☐ |
| 13.2 | Every empty state has one next action | ☐ | ☐ |
| 13.3 | Every error says what to do next | LocalizedError style | ☐ | ☐ |
| 13.4 | Loading never looks stuck > few seconds without progress | ☐ | ☐ |
| 13.5 | Haptics only where helpful (iOS) | ☐ | — |
| 13.6 | Transitions match system apps | Photos-like, not flashy | ☐ | ☐ |
| 13.7 | No placeholder / TODO / beta strings | Search + tap every button | ☐ | ☐ |
| 13.8 | Demo banner never confusable with real library | ☐ | ☐ |
| 13.9 | Grid doesn’t jump under thumb | ☐ | ☐ |
| 13.10 | Viewer chrome auto-hides sensibly | ☐ | ☐ |
| 13.11 | Backup tab readable at a glance | Counts + one primary CTA | ☐ | ☐ |
| 13.12 | Kill app on every main screen | No crash on resume | ☐ | ☐ |
| 13.13 | Rotate / fold / multi-window if claimed | ☐ | ☐ |
| 13.14 | iPad compatibility mode (iPhone app) | No crash | ☐ | — |
| 13.15 | Brand colours from tokens | Accent / status colours match design | ☐ | ☐ |

---

## Phase 14 — Store, network, compliance

| # | Scenario | How to test | iOS | And |
|---|---|---|---|---|
| 14.1 | Release build has no debug hooks | No UITest flags / demo shortcuts beyond intended review path | ☐ | ☐ |
| 14.2 | Airplane → online | Clear state; resume | ☐ | ☐ |
| 14.3 | IPv6-only (NAT64) | Demo works; real sign-in like official Telegram | ☐ | ☐ |
| 14.4 | Oldest supported OS | Install + Phase 1 smoke | ☐ | ☐ |
| 14.5 | Newest OS | Same | ☐ | ☐ |
| 14.6 | Privacy labels / Data safety match PRIVACY.md | ☐ | ☐ |
| 14.7 | Listing discloses Telegram API | No Telegram logo/branding misuse | ☐ | ☐ |
| 14.8 | No “unlimited / never lose / free storage” claims | Copy review | ☐ | ☐ |
| 14.9 | Screenshots match build | ☐ | ☐ |
| 14.10 | Review notes + demo video (iOS) | Sign-in path documented | ☐ | — |
| 14.11 | Play internal track install | Signed release APK/AAB | — | ☐ |
| 14.12 | Export compliance / encryption answers | Store forms | ☐ | ☐ |

Full store paperwork: [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md).

---

## Phase 15 — Cross-platform gate (Phase N)

**Android may write to the real library only after this is green.**

| # | Scenario | How to test | Pass |
|---|---|---|---|
| 15.1 | iPhone → Android: photo opens, SHA / size match caption | ☐ |
| 15.2 | iPhone → Android: video streams and plays | ☐ |
| 15.3 | iPhone → Android: Live Photo behaviour | ☐ |
| 15.4 | Android → iPhone: photo / Motion / video | ☐ |
| 15.5 | Split large video both ways | ☐ |
| 15.6 | Interrupted upload both ways → complete, no dup | ☐ |
| 15.7 | Save to phone both ways usable | ☐ |
| 15.8 | Favorites / albums / trash notes both ways | ☐ |
| 15.9 | Parity audit written (every iOS feature mapped or justified) | ☐ |
| 15.10 | Android 10 / 13 / 14 / 15 / 16 smoke of Phase 1 | ☐ |
| 15.11 | Mac open same library (if shipping Mac) | ☐ |
| 15.12 | Privacy policy mentions Android | ☐ |

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

| # | Scenario | iOS | And | Mac |
|---|---|---|---|---|
| M.1 | Debug unlock Pro → Locked / Cleanup / Search things / Themes unlock | ☐ | ☐ | ☐ |
| M.2 | Turn Pro off → gold **PRO** + paywall / unlock row | ☐ | ☐ | ☐ |
| M.3 | Free: backup, restore, Free Up, encryption still work | ☐ | ☐ | ☐ |
| M.4 | Lock one backed-up photo on phone → open Locked on Mac (and Android) → same photo | ☐ | ☐ | ☐ |
| M.5 | Smart Cleanup: estimate while Free; delete only after Pro + confirm | ☐ | ☐ | ☐ |
| M.6 | Search a “thing” label: Free → Pro gate; Pro → results | ☐ | ☐ | ☐ |

### 16A — Billing & entitlement

| # | Scenario | How to test | iOS | And | Mac |
|---|---|---|---|---|---|
| 16A.1 | Paywall copy is short and honest | No storage/speed lies | ☐ | ☐ | ☐ |
| 16A.2 | Start yearly trial | Store sheet; entitlement unlocks | ☐ | — | ☐ |
| 16A.3 | Buy monthly | Unlock | ☐ | — | ☐ |
| 16A.4 | Buy lifetime (if offered) | Unlock; survives relaunch | ☐ | — | ☐ |
| 16A.5 | Cancel mid-sheet | Stays Free; no half-state | ☐ | ☐ | ☐ |
| 16A.6 | Restore Purchases | New install / second device same store account | ☐ | — | ☐ |
| 16A.7 | Redeem offer / founder code | App Store Connect offer codes → system Redeem sheet | ☐ | — | ☐ |
| 16A.8 | Expired trial → Free | Pro features lock; Free core intact | ☐ | — | ☐ |
| 16A.9 | Debug unlock never in release | Release build: no Debug toggle | ☐ | ☐ | ☐ |
| 16A.10 | Family Sharing / Play family (when shipped) | Member gets Pro as designed | ☐ | ☐ | ☐ |
| 16A.11 | Offline with valid entitlement | Pro still works | ☐ | ☐ | ☐ |
| 16A.12 | Free user never blocked from backup/restore/encryption/Free Up | Explicit regression | ☐ | ☐ | ☐ |

### 16B — Locked folder (Tier A)

MetaLog: caption `CGM1:` / `CGM1E:`, ops `lock` / `unlock` (same family as favorites/albums). Does **not** move photo files.

| # | Scenario | How to test | iOS | And | Mac |
|---|---|---|---|---|---|
| 16B.1 | Free user hits Face ID / lock gate → paywall | ☐ | ☐ | ☐ |
| 16B.2 | Pro: Face ID / passcode / phone lock / Touch ID | Mac: Touch ID or login password | ☐ | ☐ | ☐ |
| 16B.3 | Hide items into locked folder | Gone from main timeline, search, memories | ☐ | ☐ | ☐ |
| 16B.4 | Unlock → items visible | ☐ | ☐ | ☐ |
| 16B.5 | App background → re-lock (grace) + app-switcher blur | ☐ | ☐ | ☐ |
| 16B.6 | Wrong auth → no peek | ☐ | ☐ | ☐ |
| 16B.7 | Move out of locked folder | Timeline restore; Telegram media unchanged | ☐ | ☐ | ☐ |
| 16B.8 | Backup still includes locked items | Bytes stay in channel; Free Up excludes locked | ☐ | ☐ | ☐ |
| 16B.9 | Recovery if biometrics change | Device passcode fallback | ☐ | ☐ | ☐ |
| 16B.10 | Feels private like Google’s Locked Folder | Side-by-side UX check | ☐ | ☐ | ☐ |
| 16B.11 | Two devices same library | Lock on A → open Locked on B; hidden on B | ☐ | ☐ | ☐ |
| 16B.12 | Unlock on B | Appears on A after sync | ☐ | ☐ | ☐ |
| 16B.13 | Airplane then sync | Pending lock note sends when online | ☐ | ☐ | ☐ |
| 16B.14 | Phone-only then backup | Pending hide → lock note after backup | ☐ | ☐ | ☐ |
| 16B.15 | E2E vs plain honesty | Copy says Telegram may still list files unless E2E | ☐ | ☐ | ☐ |
| 16B.16 | Gold **PRO** on Locked entry / toolbar | ☐ | ☐ | ☐ |
| 16B.17 | Mac empty but phone has item | Unlock+lock again on phone so the note sends; reopen Locked on Mac | ☐ | ☐ | ☐ |

### 16C — Smart cleanup (Tier A)

Exact Telegram/phone duplicates stay **Free**. Similar / screenshots / large videos (+ blurry on Apple when scored) are **Pro**. Estimate before pay.

| # | Scenario | How to test | iOS | And | Mac |
|---|---|---|---|---|---|
| 16C.1 | Free Up Space still Free | No paywall on classic Free Up | ☐ | ☐ | ☐ |
| 16C.2 | Smart cleanup entry → paywall for Free | Gold **PRO** on entry | ☐ | ☐ | ☐ |
| 16C.3 | Groups: similar, screenshots, large videos (+ blurry Apple) | ☐ | ☐ | ☐ |
| 16C.4 | Shows estimated space freed **before** pay | ☐ | ☐ | ☐ |
| 16C.5 | Pro: select extras → delete phone / backup safely | ☐ | ☐ | ☐ |
| 16C.6 | Never deletes without confirm | ☐ | ☐ | ☐ |
| 16C.7 | Feels smarter than plain Free Up | User would pay test | ☐ | ☐ | ☐ |

### 16D — Smart search (Tier A)

Free: places, dates, kinds, filenames/albums. Pro: things in the photo. OCR text-in-photo is Apple-only for now.

| # | Scenario | How to test | iOS | And | Mac |
|---|---|---|---|---|---|
| 16D.1 | Basic name/date/place search stays Free | ☐ | ☐ | ☐ |
| 16D.2 | Visual / “beach” / things → Pro gate at need | ☐ | ☐ | ☐ |
| 16D.3 | Results feel Google-Photos-good on phone library | ☐ | ☐ | ☐ |
| 16D.4 | ML only on local Photos; not Telegram downloads | ☐ | ☐ | ☐ |
| 16D.5 | Indexing progress clear; battery OK | ☐ | ☐ | ☐ |
| 16D.6 | Gold **PRO** on Smart Search teaser when Free | ☐ | ☐ | ☐ |

### 16E — Memories polish & desktop folder (Tier A)

| # | Scenario | How to test | iOS | And | Mac |
|---|---|---|---|---|---|
| 16E.1 | Base Memories stay Free (on this day / recent / trips) | ☐ | ☐ | ☐ |
| 16E.2 | Themes gated Pro; gold **PRO** on Themes when Free | ☐ | ☐ | ☐ |
| 16E.3 | Folder / second copy Pro; viewer/restore Free | ☐ | ☐ | ☐ |
| 16E.4 | Folder watch / SD / Downloads / SAF path | — | ☐ | ☐ |

### 16F — Tier B (when built)

| # | Scenario | How to test | Pass |
|---|---|---|---|
| 16F.1 | Free: one library; Pro: more libraries | ☐ |
| 16F.2 | Family plan seats | ☐ |
| 16F.3 | Streaming / fast copies extras | ☐ |
| 16F.4 | Advanced map / stats | ☐ |
| 16F.5 | Widgets / icons / themes | ☐ |
| 16F.6 | Priority support path (process, not magic) | ☐ |

### 16G — Pro “would I pay?” review (human)

Run once per Pro wedge with a cold user or yourself after 24 hours away:

| # | Question | Yes |
|---|---|---|
| 16G.1 | Did I hit the paywall at a moment of real need? | ☐ |
| 16G.2 | Did I see a concrete benefit before Apple/Google sheet? | ☐ |
| 16G.3 | Is Free still a complete backup app I’m proud of? | ☐ |
| 16G.4 | Would I pay yearly at the listed price for this one feature alone? | ☐ |
| 16G.5 | Would I be embarrassed if a reviewer compared us to Google Photos Locked Folder / search? | ☐ (want No) |

If 16G.4 is No for the first wedge, **do not ship billing yet** — polish that wedge.

---

## Suggested schedule

| Day | Focus |
|---|---|
| 1 | Phase 1 both phones |
| 2 | Phases 2–4 |
| 3 | Phases 5–7 |
| 4 | Phases 8–10 |
| 5 | Phases 11–12 + 15 start |
| 6 | Phases 13–14 store |
| 7 | Phase 15 finish; Android real-library decision |
| Later | Phase 16 when each Pro wedge is feature-complete |

---

## Appendix A — Mac (when shipping)

Smoke: sign-in, unlock library, timeline, viewer, video, save, Free Up (if offered), Settings, sign out.
Pro: folder backup entitlement; viewer/restore remain Free.
Parity: open library written by iPhone and Android.

---

## Appendix B — Import / Takeout (Free forever)

| # | Scenario | Pass |
|---|---|---|
| B.1 | Google Takeout import path completes without paywall | ☐ |
| B.2 | Drive import if shipped | ☐ |
| B.3 | Failures explain next step; no silent skips | ☐ |

---

## Appendix C — Scorecard

| Phase | iOS | Android | Ship? |
|---|---|---|---|
| 1 Trust core | ☐ | ☐ | Must |
| 2 Sign-in / library | ☐ | ☐ | Must |
| 3 Gallery | ☐ | ☐ | Must |
| 4 Viewer | ☐ | ☐ | Must |
| 5 Collections | ☐ | ☐ | Must for feature parity |
| 6 Search | ☐ | ☐ | Must for feature parity |
| 7 Backup deep | ☐ | ☐ | Must |
| 8 Free Up / restore | ☐ | ☐ | Must |
| 9 Background | ☐ | ☐ | Strongly before 1.0 |
| 10 Settings | ☐ | ☐ | Must |
| 11 Cross-device sync | ☐ | ☐ | Must before dual-store story |
| 12 Similar | ☐ | ☐ | If shipped |
| 13 Polish | ☐ | ☐ | World-class bar |
| 14 Store | ☐ | ☐ | Must |
| 15 Gate N | ☐ | ☐ | Must before Android real writes |
| 16 Pro | ☐ | ☐ | Before charging |

---

## Opinion (keep product honest)

World-class here means **trust first**: false “backed up” or a bad Free Up is worse than a missing Memories polish.
Pro should feel like Google Photos intelligence **on storage you already own** — Locked Folder and Smart Cleanup
that show “private” or “GB freed” at the moment of need. If Free is incomplete, Pro feels like a ransom; if Free is
excellent and Pro is clearly smarter, people pay.

Update this file when a feature ships or a hard Free/Pro rule changes. Date the change in the commit message.
