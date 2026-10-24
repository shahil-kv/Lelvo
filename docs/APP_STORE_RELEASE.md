# App Store release checklist (iOS)

Step-by-step list of everything to fix, prepare and submit so App Review approves the iOS app on the first try.
Work top to bottom; each phase depends on the ones before it. Tick boxes as you go.

No checklist can guarantee approval: App Review is done by people and guidelines change. This list covers every
known rejection reason that applies to this app, as of October 2026. Re-read the current
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) before submitting.

Legend: ✅ already done in the code · 🔧 code change needed · 📝 paperwork / App Store Connect · 🧪 testing

---

## Phase 0 — Accounts and keys (do first)

- [ ] 📝 **Apple Developer Program** ($99/year) at developer.apple.com/programs. Enrol as an *Individual*; your legal
      name is shown as the seller.
- [ ] 📝 **Separate Telegram account for the app's API key.** Use a spare SIM or number, not your personal account.
      Log in at https://my.telegram.org → *API development tools* → create an app (title = the App Store name,
      platform iOS). Put the new `api_id` / `api_hash` into `Config/Secrets.xcconfig`:
      ```
      TD_API_ID = <new id>
      TD_API_HASH = <new hash>
      ```
      Why: if Telegram ever flags the app, the warning and any action land on that account, not your personal one.
- [ ] 📝 Add the same keys as GitHub secrets so CI builds have them:
      ```bash
      gh secret set TD_API_ID --body "<new id>"
      gh secret set TD_API_HASH --body "<new hash>"
      ```
- [ ] 📝 Keep the old (personal) api_id only for local debug builds, or revoke it.

---

## Phase 1 — Legal blockers (rejection or takedown risk)

### 1.1 License: GPL-3.0 plus a CLA ✅

The project is GPL-3.0 ([LICENSE](../LICENSE)). The FSF considers the App Store's usage rules an extra restriction
the GPL forbids when someone else's GPL code is distributed (VLC was removed for this in 2011). The maintainer can
publish their own code anyway, so the project keeps every contribution publishable:

- ✅ All code in the repository was written by the maintainer; no upstream (AKS-Labs) or Whitehole code is included
  (history rebuilt with only the maintainer's commits).
- ✅ Every contribution is accepted under [CLA.md](../CLA.md), which allows App Store distribution, enforced by the
  CLA workflow.
- ✅ Settings → About states the GPL-3.0, links the source code, and has an Acknowledgements screen with the
  third-party licenses (TDLib BSL-1.0, TDLibKit and TDLibFramework MIT with the full notice, OpenSSL Apache-2.0).
  Same list in [NOTICE.md](../NOTICE.md).
- [ ] 📝 Before the first submission, confirm every merged contributor has signed the CLA (the `cla-signatures`
      branch).

### 1.2 Name and branding 🔧📝

- [ ] 📝 Pick an **App Store name that isn't "CloudGallery" or "Chitralaya"**. Those names belong to upstream, and
      a name collision gets apps rejected (4.1) or disputed. Check the name is free by searching the App Store, and
      reserve it in App Store Connect (Phase 5).
- [ ] 🔧 Rename `CFBundleDisplayName` in `project.yml` (both targets) to the new name. The bundle ID
      `com.shahil-kv.cloudgallery` can stay.
- [ ] 🔧 **Must not contain "Telegram"** in the app name, subtitle, icon or keywords (Telegram API terms 2.3;
      Apple 5.2.1 — trademark). Saying "works with your Telegram account" in the description is fine.
- [ ] 🔧 App icon: no paper plane, no Telegram blue circle, and nothing resembling Apple Photos' flower (4.1
      copycat). Original artwork only.
- [ ] ✅ In-app disclosure "Uses the Telegram API. Not affiliated with Telegram." on the welcome screen
      (Telegram API terms 2.2).

### 1.3 Telegram API terms (https://core.telegram.org/api/terms)

- ✅ Own api_id (2.1) · ✅ disclosure (2.2) · 🔧 name/logo (1.2 above)
- ✅ No ghost mode, no read-receipt or typing tampering, no acting without consent (1.4)
- ✅ No AI training on user data (1.5) · ✅ no ads or monetization (3.x)
- ✅ Respects FLOOD_WAIT, only 2 parallel uploads (keeps the api_id in good standing)
- ✅ If Telegram refuses the built-in key at sign-in, the app falls back to "enter your own key"
      (`OnboardingModel.run`)
- [ ] 🔧 Optional: handle a refused key for users who are *already signed in* (currently only sign-in handles it).

---

## Phase 2 — App Review sign-in (No. 1 rejection reason: Guideline 2.1)

The reviewer must be able to use every feature. A Telegram login code goes to the account's other Telegram sessions
or by SMS, which the reviewer can't receive. Without a way in, rejection under 2.1 ("unable to sign in") is almost
certain.

### 2.1 Reviewer demo mode 🔧

Build a demo mode that a special phone number unlocks. Apple accepts "a fully-featured demo mode" in place of a demo
account.

- [ ] 🔧 On the phone step, if the number equals a reserved reviewer number (e.g. `+1 555 010 0199`, which can't be a
      real Telegram number), don't contact Telegram. Go to the code step, and accept a fixed code (e.g. `24680`).
- [ ] 🔧 Then load a **demo library**: reuse `UITestSupport.prepareIfNeeded()` (`Shared/App/AppModel.swift`, Debug-only today),
      but make it work in Release:
  - [ ] Real sample photos and videos bundled in the app (about 40 royalty-free images and 2–3 short clips you own),
        not grey tiles. `seedDemoThumbnails` is currently `#if DEBUG` only.
  - [ ] Viewer opens photos and plays a video.
  - [ ] Backup screen shows a simulated backup running (progress, then "backed up" badges), because the reviewer will
        look for the core feature.
  - [ ] Pinch columns, select, share, save to Photos all work.
  - [ ] Settings → Sign out returns to the welcome screen and clears demo data.
- [ ] 🔧 Show a small "Demo library" banner while in demo mode, so it's clearly a demo and not a fake library.
- [ ] 🔧 Make sure demo mode never touches a real Telegram session or the user's Photos library, apart from the
      Photos permission prompt.
- [ ] 🧪 Test the whole demo on a clean install of a **Release** build from TestFlight, not a Debug build.

### 2.2 Proof that the real flow works 📝

- [ ] 📝 Record a 1–2 minute screen video of the *real* flow: sign in with a real Telegram account → create the
      library → back up a few photos → see them in the channel in the official Telegram app → restore on another
      device or after reinstall. Upload it (unlisted YouTube, or a Drive link) and link it in the review notes.

### 2.3 Review notes (paste into App Store Connect → App Review Information → Notes) 📝

```
This app backs up the user's own photos and videos to a private channel in the user's own
Telegram account, using the official Telegram API (TDLib). We run no servers and collect no data.

DEMO ACCESS (no Telegram account needed):
1. Tap "Continue with Telegram".
2. Enter phone number +1 555 010 0199 and tap Next.
3. Enter code 24680.
A demo library with sample photos loads; every feature (timeline, viewer, video playback,
backup progress, selection, sharing, settings) works in the demo.

REAL FLOW: signing in with a real number sends the login code to that account's Telegram app.
A video of the real sign-in and backup is here: <link>

Telegram allows third-party apps through its API (https://core.telegram.org/api/terms);
the app follows those terms (own api_id, disclosure on the welcome screen).

Background modes: "audio" is used for Picture in Picture video playback; "processing" and
"fetch" are used to continue the user-started photo backup.
```

- [ ] 📝 Fill in contact name, phone and email in App Review Information, and answer within hours while in review.

---

## Phase 3 — Technical requirements

### 3.1 Privacy manifest (required; upload is rejected or flagged without it) 🔧

✅ Added: `iOS/Resources/PrivacyInfo.xcprivacy` and `macOS/Resources/PrivacyInfo.xcprivacy` (no tracking, no
collected data; UserDefaults `CA92.1`, file timestamps `C617.1` + `3B52.1`, disk space `E174.1`). TDLibFramework ships
no manifest of its own and calls `stat`/`statfs`, which the app manifest covers. What it declares:

- ✅ Privacy manifest with:
  - `NSPrivacyTracking` = false, `NSPrivacyTrackingDomains` = []
  - `NSPrivacyCollectedDataTypes` = [] (nothing is collected by you)
  - `NSPrivacyAccessedAPITypes`:
    - `NSPrivacyAccessedAPICategoryUserDefaults` — reason `CA92.1` (app's own settings)
    - `NSPrivacyAccessedAPICategoryFileTimestamp` — reason `C617.1` (files in the app container), plus `3B52.1`
      if timestamps of user-picked files are read
    - `NSPrivacyAccessedAPICategoryDiskSpace` — reason `E174.1` (check space before downloads/exports), only if
      the app reads free disk space
    - `NSPrivacyAccessedAPICategorySystemBootTime` — reason `35F9.1`, only if `systemUptime` /
      `mach_absolute_time` is used
- ✅ TDLibKit / TDLibFramework ship no privacy manifest; the app's manifest covers their API use.
- [ ] 🧪 After archiving: Xcode Organizer → right-click archive → *Generate Privacy Report*, and check nothing is
      missing.

### 3.2 Background modes (2.5.4) 🧪

`UIBackgroundModes` = `audio`, `fetch`, `processing`.

- [ ] 🧪 `audio`: allowed only because the viewer supports Picture in Picture video. Verify PiP actually keeps playing
      audio in the background. If PiP is removed, remove `audio`; silent-audio keep-alive is an instant rejection.
- [ ] ✅ `fetch` / `processing`: `BGAppRefreshTask` and `BGProcessingTask` are registered, and identifiers are listed in
      `BGTaskSchedulerPermittedIdentifiers`.
- [ ] 🧪 Backups must not keep the app alive by tricks (no silent audio, no fake location). Only BGTasks and
      `BGContinuedProcessingTask`.

### 3.3 Device support 🔧

`TARGETED_DEVICE_FAMILY = "1,2"` means you claim iPad support, so the reviewer may test on an iPad, and iPad
screenshots become mandatory.

- [ ] 🔧 **Recommended for v1:** set `TARGETED_DEVICE_FAMILY: "1"` (iPhone only) in `project.yml`. Reviewers
      still run iPhone apps on iPad in compatibility mode, so the app must not crash or look broken there.
- [ ] 🧪 Or keep iPad: then test every screen on an iPad simulator in both orientations, plus Split View and Stage
      Manager, and make 13" iPad screenshots.

### 3.4 Build hygiene 🔧🧪

- [ ] 🔧 Build with the current Xcode / iOS SDK (Apple requires the latest SDK for new uploads).
- [ ] 🔧 Version: `MARKETING_VERSION` (e.g. 2.0.0) and a unique, increasing `CURRENT_PROJECT_VERSION` for every
      upload.
- ✅ Release builds don't expose debug features: `-UITestReset`, `-UITestDemoLibrary`, `-autoScrollTest`,
      `-verifyCloudReads*` and `-clearCacheTest` are compiled only in Debug (`#if DEBUG`).
- [ ] 🔧 No placeholder text, "TODO", "beta", "test" or lorem ipsum anywhere visible (2.1, 2.3).
- [ ] 🔧 Every button does something; no "coming soon" items (2.1).
- ✅ Settings → About links the **Privacy Policy** ([PRIVACY.md](../PRIVACY.md)), the FAQ and issue reporting.
- [ ] 🔧 Settings must offer **Sign out** and **remove all app data from this device**. Account deletion (5.1.1(v))
      isn't required because the app never creates Telegram accounts. If the reviewer asks, explain that accounts
      are created in Telegram, and link Telegram's own deletion page (https://my.telegram.org/delete).

### 3.5 Network and stability 🧪

- [ ] 🧪 **IPv6-only network.** App Review uses one. On a Mac: System Settings → Sharing → Internet Sharing with
      "Create NAT64 network", and connect the iPhone to it. Test sign-in, backup, viewer.
- [ ] 🧪 Airplane mode, then back online: no crash, clear message, backup resumes.
- [ ] 🧪 Photos permission: denied, limited ("Select Photos…"), full. Every case shows a sensible screen, and denying
      doesn't trap the user (5.1.1(iv): don't force the permission; allow using the app as a viewer of the cloud
      library without it).
- [ ] 🧪 Notifications permission (if requested): only ask when it makes sense, not at first launch.
- [ ] 🧪 Fresh install on the oldest supported iOS (17.0) and the newest. No crash on launch.
- [ ] 🧪 Large library (10k+ photos) and low storage: no crash.
- [ ] 🧪 Kill the app mid-backup and relaunch: resumes, no duplicates.
- [ ] 🧪 Dark mode, light mode, the largest Dynamic Type size, VoiceOver basics on the main screens.

### 3.6 Export compliance (encryption) 📝

The app uses encryption: TDLib/MTProto via OpenSSL, plus CryptoKit AES-GCM for encrypted libraries. All of it is
standard and published algorithms, used to protect the user's own data, which counts as mass-market.

- [ ] 📝 `ITSAppUsesNonExemptEncryption = false` is set. Answer the App Store Connect encryption questions
      consistently with that: the app uses encryption, it qualifies for the exemptions (mass-market, standard
      algorithms, protecting user data, not a security product).
- [ ] 📝 **France:** App Store Connect may require a French encryption declaration for apps with non-Apple
      encryption. Simplest for v1: leave France out of availability, or file the declaration with ANSSI.
- [ ] 📝 If App Store Connect asks for documentation anyway, follow its prompts. Don't change the Info.plist answer
      to hide encryption.

---

## Phase 4 — Privacy policy and support pages 📝

Host both on GitHub Pages (free), e.g. `https://shahil-kv.github.io/<app>/privacy`.

- [ ] 📝 **Privacy policy**, in plain words, covering:
  - Who you are (your name, contact email).
  - The app has no servers and collects no personal data, analytics, crash reports or tracking.
  - Photos and videos are sent only from the user's device to the user's own Telegram account (a private channel
    they own), through Telegram's API; Telegram's privacy policy applies to data stored there (link
    https://telegram.org/privacy).
  - Phone number and login code go only to Telegram, to sign in.
  - Encrypted libraries: the passphrase never leaves the device; nobody, including you, can recover it.
  - Data stored on device: thumbnails cache, library index, settings. Removed by "Sign out & remove data" or by
    deleting the app.
  - Children: not directed at children under 13.
  - How users can contact you; date of the policy.
- [ ] 📝 **Support page** with a contact email and a short FAQ: how to sign in, where photos are stored, what if I
      lose my passphrase, how to restore on a new phone. A support URL is required.
- [ ] 📝 Optional: a marketing URL, which can be the same site.

---

## Phase 5 — App Store Connect setup 📝

### 5.1 Create the app

- [ ] Register the bundle ID `com.shahil-kv.cloudgallery` in developer.apple.com → Identifiers. Enable only the
      capabilities the app uses (Background Modes are Info.plist-only; no Push, no iCloud unless used).
- [ ] App Store Connect → My Apps → **+** → New App: platform iOS, the new name, primary language, bundle ID, SKU
      (e.g. `photobackup-ios-1`).
- [ ] Separate Mac app (`com.shahil-kv.cloudgallery.mac`): a separate submission later with its own checklist run
      (sandbox entitlements, notarization not needed for the Mac App Store). Ship iOS first.

### 5.2 App information

- [ ] Category: **Photo & Video** (secondary: Utilities).
- [ ] Content rights: "Does not contain, show, or access third-party content". The app shows only the user's own
      media. If App Store Connect insists because of Telegram, answer yes and state you have the right under
      Telegram's API terms.
- [ ] **Age rating** questionnaire: answer "None" for everything; user-generated content **No** (users see only their
      own photos, with no sharing between users and no social features); unrestricted web access **No**.
      Expected result: 4+.
- [ ] Price: Free. Availability: all countries (or all except France, see 3.6).
- [ ] No in-app purchases, no ads, no external payment or donation links in the app (3.1.1). A "donate" link in the
      app would need In-App Purchase; leave it out of v1.

### 5.3 App Privacy ("nutrition label")

- [ ] Data collection: **"No, we do not collect data from this app."** This is correct because you (the developer)
      receive nothing; data goes from the device to the user's own Telegram account. Apple defines "collect" as
      transmitting off the device in a way you or your partners can access, and you can't access it.
- [ ] Privacy policy URL from Phase 4.

### 5.4 Store listing text (Guideline 2.3 — accurate metadata)

Rules:
- No "unlimited", "free forever", or "never lose" claims about Telegram storage (2.3.1). Telegram's limits and
  terms are not yours to promise.
- No mention of Android or other platforms (2.3.10).
- No "Telegram" in the name, subtitle or keywords (trademark). In the description, factual use only.
- No mention of other apps' names as keywords (Google Photos, iCloud…) (2.3.7).

Templates to adapt:

- **Subtitle (30 chars):** `Back up photos to your channel`
- **Keywords (100 chars):** `photo backup,video backup,gallery,private,encrypted,restore,cloud,timeline,albums,storage`
- **Promotional text:** `Back up your photo library to a private channel in your own account, and browse it in one timeline.`
- **Description:**
  ```
  Back up your photos and videos to a private channel in your own Telegram account, and
  browse your whole library in one fast timeline.

  • Original quality backups of photos, Live Photos and videos
  • One timeline for photos on this iPhone and in your backup
  • Stream backed-up videos without downloading them first
  • Optional end-to-end encryption with your own passphrase
  • Restore everything on a new iPhone by signing in
  • Background backup that continues where it left off

  Your data stays yours: the app has no servers, no accounts of its own, no analytics and
  no ads. Photos go directly from your iPhone to your own Telegram account.

  This app uses the Telegram API. It is not affiliated with or endorsed by Telegram.
  Storage in your Telegram account is subject to Telegram's terms.
  ```
- [ ] Copyright: `2026 <Your Legal Name>`.
- [ ] Support URL, Privacy URL, (Marketing URL).

### 5.5 Screenshots

- [ ] iPhone **6.9"** (1320 × 2868 or 1290 × 2796), 3–10 images. Apple scales them for smaller iPhones.
- [ ] iPad **13"** (2064 × 2752) only if iPad stays supported (3.3).
- [ ] Use real app screens (2.3.3), and use demo-library photos you own. No real people's faces without permission,
      no Telegram logo, and no device frames showing other brands.
- [ ] Suggested set: timeline · viewer · backup progress · encrypted library setup · restore screen.
- [ ] Optional App Preview video (15–30 s, real screen recording).

---

## Phase 6 — TestFlight dry run 🧪

External TestFlight goes through a light Beta App Review. It's the cheapest way to catch problems before the real
review.

- [ ] Archive: Xcode → Product → Archive (Release, Generic iOS Device), then Distribute → App Store Connect → Upload.
      Or use CI.
- [ ] Fix any email from App Store Connect after upload (ITMS-9xxxx warnings: privacy manifest, missing usage
      strings, icons).
- [ ] Internal testing on your own iPhone: run the whole Phase 3.5 list on the TestFlight build.
- [ ] External testing: add 2–5 testers and submit for Beta App Review with the same demo notes (Phase 2.3). Approval
      here is a strong sign the main review will pass.
- [ ] Ask testers to try: fresh sign-in, backup of 500+ items, restore on another device, encrypted library.

---

## Phase 7 — Submit for review 📝

- [ ] Select the TestFlight build on the version page.
- [ ] Fill in "What's New" for v1 ("First release.").
- [ ] App Review Information: demo instructions (2.3), contact details, attach the real-flow video link.
- [ ] Release option: **Manually release this version**, so you control the launch moment.
- [ ] Submit. Typical review time is 24–48 h.
- [ ] Watch email and App Store Connect → *Resolution Center*. Reply politely and specifically within a day.

---

## Phase 8 — If it gets rejected

| Rejection | What it means | Fix / reply |
|---|---|---|
| **2.1 Information Needed / can't sign in** | Reviewer couldn't get in | Point to the demo number and code; check demo mode works on the build under review; re-send the video link. |
| **2.1 App Completeness — crash** | Crash on their device | Get the crash log from App Store Connect → TestFlight → Crashes; often IPv6-only network or iPad. Fix, upload a new build. |
| **2.3.x Metadata** | Claims, keywords, screenshots | Remove "unlimited", the Telegram name from keywords, or Android mentions. Metadata-only fixes don't need a new build. |
| **4.1 Copycat / 5.2.1 Intellectual Property** | Name or icon looks like Telegram, Apple Photos or upstream | Rename, redraw the icon. Reply that the Telegram API terms allow third-party clients (link). |
| **5.2.2 Third-party service** | "Do you have permission to use Telegram?" | Reply: Telegram's API is public and free for third-party apps under https://core.telegram.org/api/terms; the app uses its own registered api_id and complies (disclosure on the welcome screen). |
| **5.1.1 Privacy policy / permissions** | Missing policy link in app, or permission purpose strings too vague | Add the in-app link; make `NSPhotoLibraryUsageDescription` specific (it already is). |
| **5.1.1(v) Account deletion** | Reviewer thinks the app creates accounts | Reply: the app never creates accounts; users sign in with an existing Telegram account, deletable at https://my.telegram.org/delete; the app offers sign-out and on-device data removal. |
| **2.5.4 Background modes** | Reviewer thinks `audio` is abused | Explain PiP video playback; show where it's used. If PiP is gone, remove `audio`. |
| **4.2 Minimum functionality** | Rare | Point out the backup engine, encryption, restore and streaming: it's a full app, not a web wrapper. |

If a reply doesn't help, you can appeal to the App Review Board (App Store Connect → Resolution Center → appeal).

---

## Phase 9 — After approval

- [ ] Release manually.
- [ ] Watch crashes in Xcode Organizer → Crashes for the first week.
- [ ] Keep the Telegram app account (Phase 0) active. Telegram deletes inactive accounts, by default after 6 months;
      set *Settings → Privacy → Delete my account if away* to the maximum.
- [ ] Before each update: re-run Phase 3.5, bump `CURRENT_PROJECT_VERSION`, and keep the demo mode working, because
      every update is reviewed again.
- [ ] If Telegram ever revokes the api_id: create a new one on the app account, ship an update. Users meanwhile can
      enter their own keys (already built in).

---

## Quick status

| Item | Status |
|---|---|
| Telegram disclosure on welcome screen | ✅ done |
| Fallback to own keys if built-in key refused (sign-in) | ✅ done |
| FLOOD_WAIT handling, limited parallel uploads | ✅ done |
| Encryption Info.plist key | ✅ set (`false`) |
| Photo permission strings | ✅ done |
| Background task identifiers | ✅ done |
| Separate Telegram account for api_id | ⬜ Phase 0 |
| GPL-3.0 + CLA, acknowledgements in About | ✅ Phase 1.1 |
| New app name + original icon | ⬜ Phase 1.2 |
| Reviewer demo mode (Release build, real sample media) | ⬜ Phase 2.1 |
| PrivacyInfo.xcprivacy (iOS and Mac) | ✅ Phase 3.1 |
| iPhone-only or full iPad support decision | ⬜ Phase 3.3 |
| Privacy policy link + sign-out & remove data in Settings | ✅ Phase 3.4 |
| Privacy policy + support pages (PRIVACY.md, SUPPORT.md, docs/FAQ.md) | ✅ written · ⬜ host on GitHub Pages |
| App Store Connect listing, privacy label, screenshots | ⬜ Phase 5 |
| TestFlight external beta passed | ⬜ Phase 6 |
