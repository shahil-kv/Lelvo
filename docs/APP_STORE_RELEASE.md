# App Store release checklist (iOS)

Step-by-step list of everything to fix, prepare and submit so App Review approves the iOS app on the first try.
Work top to bottom; each phase depends on the ones before it. Tick boxes as you go.

No checklist can guarantee approval: App Review is done by people and guidelines change. This list covers every
known rejection reason that applies to this app, as of November 2026. Re-read the current
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) before submitting.

Legend: ✅ already done in the code · 🔧 code change needed · 📝 paperwork / App Store Connect · 🧪 testing

---

## TestFlight or App Store first?

**TestFlight first, then the App Store.** It's one pipeline, not two: you upload one build to App Store Connect, test
it in TestFlight, and submit that same build for review. The Play Store is Android only and Lelvo has no Android app,
so it doesn't apply.

| | Internal TestFlight | External TestFlight | App Store |
|---|---|---|---|
| Who can install | Up to 100 people on your App Store Connect team | Up to 10,000 people, by email or public link | Everyone |
| Apple review | None | First build added to a group; later builds may skip full review | Full App Review |
| How long until people can install | Minutes, after 10–30 minutes of processing | After that review; Apple gives no figure | Your choice after approval |
| Builds last | 90 days | 90 days | Until you remove it |
| Needs | Developer Program, app record, upload | Those, plus test information and review notes | Those, plus the full listing (Phase 5) |

External TestFlight reviews the same login and demo problem as the App Store, so it's the cheapest early warning.
The order is: internal → external → App Store.

**Installing:** testers install Apple's free TestFlight app, then open the invitation email or public link. Internal
testers need access to your App Store Connect team, so use external testing for friends. A public link lets anyone
join without you collecting their email.

**Timing:** Apple says App Review handles at least 50% of submissions in under 24 hours and 90% in under 48 hours.
Each rejection and resubmission restarts the wait. Allow at least a week from first submission to launch.

## Do you need a domain?

**No.** Apple needs a working Privacy Policy URL and Support URL, and doesn't check who owns the domain or the bundle
ID prefix. `lelvo.mshahilkv.workers.dev` is enough to pass review.

**Still buy `lelvo.app` before the first build you submit.** The privacy link is compiled into the app
(`Shared/Support/AppLinks.swift`), and bundle IDs (`app.lelvo.*`) can't change after the first release. Once it's
bought: point it at the site, update `AppLinks.privacyPolicy` and the URLs in Phase 4, and keep the old address
redirecting, because older builds still link to it.

## The five things most likely to block approval

1. **Demo mode needs Apple's prior approval** (Guideline 2.1(a), Phase 2.1). This is the biggest risk. Ask before
   submitting.
2. **Telegram's disclosure must be prominent in the listing** (API terms 2.2, Phase 5.4). Telegram can ask stores to
   remove an app that ignores a violation for 10 days (terms 4.2).
3. **The privacy label** must be entered as decided (Phase 5.3), matching the privacy manifests.
4. **France** must be switched off by hand in availability (Phase 3.6).
5. **The CI upload has never run** (Phase 6). Expect the first run to need a fix, and allow time for it.

---

## Your workflow, start to finish

What's left is mostly yours (accounts, App Store Connect, testing on a device). In order:

1. **Join the Apple Developer Program** (Phase 0). Wait for the approval email (usually 1–2 days).
2. **Telegram key for the App Store build:** create it on a spare Telegram account (Phase 0), put it in
   `Config/Secrets.xcconfig`, and save it for CI:
   `! gh secret set TD_API_ID -R shahil-kv/Lelvo` and `! gh secret set TD_API_HASH -R shahil-kv/Lelvo`.
3. **Buy `lelvo.app`** and update the links (see above).
4. **Trademark search** for "Lelvo" in class 9 (Phase 1.2).
5. **App Store Connect:** register the bundle ID, create the app, fill in app information, age rating, privacy
   label, trader status, URLs and listing text (Phase 5). All text is ready below; copy it in.
6. **API key for uploads:** App Store Connect → Users and Access → Integrations → App Store Connect API → generate a
   key with the *App Manager* role. Then save four secrets:
   `! gh secret set APPLE_TEAM_ID -R shahil-kv/Lelvo`, `! gh secret set ASC_KEY_ID -R shahil-kv/Lelvo`,
   `! gh secret set ASC_ISSUER_ID -R shahil-kv/Lelvo`, and the key file itself:
   `! gh secret set ASC_KEY_P8 -R shahil-kv/Lelvo < ~/Downloads/AuthKey_XXXXXXXXXX.p8`.
7. **First TestFlight build:** GitHub → Actions → Release → Run workflow from `main` (app: ios, channel: beta, version 1.0.0).
   It archives, signs and uploads to App Store Connect; the build shows in TestFlight 10–30 minutes later.
   (Or archive in Xcode: Product → Archive → Distribute → App Store Connect.)
8. **Test the TestFlight build on your iPhone** (Phase 3.5 list), including the demo: sign out, enter
   `+1 555 010 0199`, code `24680`.
9. **Record the real-flow video** (Phase 2.2) and screenshots (Phase 5.5; the demo library gives clean photos).
10. **Ask App Review to approve the demo mode** (Phase 2.1). Do this before any external TestFlight submission.
11. **External TestFlight** with a few testers (Phase 6), then **submit for review** (Phase 7) with the review
    notes from Phase 2.3.
12. **After approval:** release manually and watch crashes for a week (Phase 9).

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
- [ ] 📝 Add the same keys as GitHub secrets so CI builds have them (each command asks for the value, so it never
      lands in your shell history):
      ```bash
      gh secret set TD_API_ID -R shahil-kv/Lelvo
      gh secret set TD_API_HASH -R shahil-kv/Lelvo
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

- ✅ Name: **Lelvo**, used everywhere: app, bundle IDs (`app.lelvo.ios`, `.mac`), repository. The strings
      "Memvo master key v2" and "Memvo recovery key v2" in `E2EKeys.swift` are key-derivation inputs and must stay.
- [ ] 📝 Search the name in the trademark databases before submitting (class 9). US search found no marks; still to
      check: [WIPO Global Brand Database](https://branddb.wipo.int) (includes EU marks) and
      [IP India](https://ipindiaonline.gov.in/eregister/). `lelvo.io` is an unrelated dating site with the same name.
- [ ] 📝 Reserve **Lelvo** in App Store Connect as soon as the developer account exists (Phase 5).
- [ ] 📝 **Must not contain "Telegram"** in the app name, subtitle, icon or keywords (Telegram API terms 2.3;
      Apple 5.2.1 — trademark). Saying "works with your Telegram account" in the description is fine.
- ✅ App icon: original artwork, a sunset photo folded into an L with a padlock. 1024 × 1024, no transparency. No
      paper plane or Telegram logo (terms 2.4). Screenshots must also avoid the intro's paper plane symbol.
- ✅ In-app disclosure on the welcome screen, now readable size (Telegram API terms 2.2): "Lelvo uses the Telegram API
      and is part of the Telegram ecosystem. Not affiliated with Telegram."

### 1.3 Telegram API terms (https://core.telegram.org/api/terms)

- ✅ Own api_id (2.1) · ✅ in-app disclosure (2.2) · ✅ name and logo (2.3, 2.4) · 📝 listing disclosure (Phase 5.4)
- [ ] 📝 **Before Lelvo Plus or any paid feature:** list every monetization method in the store description (3.2),
      and re-read 3.3 (sponsored messages) and 1.5 (limits on using Telegram data for AI models). Plus's AI ideas
      need checking against 1.5 first.
- [ ] 📝 Optional: ask Telegram whether a backup app is fine, and keep any reply. The API terms list no contact, so try
      https://telegram.org/support and expect that they may not answer. A "no" is better to learn before launch. Text:
      ```
      I'm building Lelvo, an independent open-source app using TDLib with its own api_id. Each user
      signs in to their own account and backs up their own photos to a private channel they own, at
      Telegram's upload limits. Does this fit the API terms? https://github.com/shahil-kv/Lelvo
      ```
- [ ] 📝 Watch the app account's Telegram messages and email. Telegram allows 10 days to fix a reported violation
      before it can end API access and contact the App Store (4.2).
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

Guideline 2.1(a) expects a demo account. A built-in demo mode is allowed only "if you are unable to provide a demo
account due to legal or security obligations" and **"with prior approval by Apple"**, and it must show the app's full
features. So having the demo isn't enough:

- [ ] 📝 **Get approval before the first external TestFlight or App Store submission.** Ask through
      [Contact App Review](https://developer.apple.com/contact/app-store/) and keep the reply and any case number:
      ```
      Lelvo signs in with the user's own Telegram account. Telegram sends a one-time code to that
      account's Telegram app or by SMS, so we can't give you a fixed password or a static code, and
      sharing login codes goes against Telegram's security guidance. We would like approval to use a
      built-in demo mode, unlocked with a test phone number, that shows every feature with sample media.
      We can also send a video of the real sign-in and backup. Is this acceptable?
      ```
- [ ] 📝 If Apple refuses: offer a real spare Telegram account and arrange a time when you can pass on the code live
      during review, and ask App Review which arrangement they accept.

✅ Built (`Shared/App/DemoMode.swift`, works in Release; UI test `UITests/DemoModeTests.swift`):

- ✅ Phone `+1 555 010 0199` (555-01xx numbers are reserved for fiction, so it can't be a real account) skips
  Telegram; code `24680` opens the demo. The phone step comes first even in builds without app keys.
- ✅ **Demo library** bundled in `iOS/DemoLibrary` (11 MB): 40 Unsplash photos and 2 short clips, with dates
  relative to today, places, favourites and albums.
- ✅ Viewer opens photos, zooms and plays the clips; share and save work (files come from the app bundle).
- ✅ **Back up now** simulates the backup: 6 waiting items upload with progress bars, then join the timeline.
  The reviewer's own photos are never marked as backed up, and Free Up Space offers nothing in the demo.
- ✅ A "Demo library: sample photos, nothing is uploaded" banner stays at the top of every tab.
- ✅ Telegram never starts in demo mode; Settings shows "Demo account"; **Sign out and reset** leaves demo mode
  and returns to the welcome screen.
- [ ] 🧪 Test the whole demo on a clean install of the **TestFlight** build, not a Debug build.
- [ ] 🔧 Later: the Mac app has no demo mode yet (needed before the Mac App Store submission).

### 2.2 Proof that the real flow works 📝

- [ ] 📝 Record a 1–2 minute screen video of the *real* flow: sign in with a real Telegram account → create the
      library → back up a few photos → see them in the channel in the official Telegram app → restore on another
      device or after reinstall. Upload it (unlisted YouTube, or a Drive link) and link it in the review notes.

### 2.3 Review notes (paste into App Store Connect → App Review Information → Notes) 📝

```
This app backs up the user's own photos and videos to a private channel in the user's own
Telegram account, using the official Telegram API (TDLib). We run no servers of our own.

DEMO ACCESS (approved by App Review on <date>, case <number>; no Telegram account needed):
1. Tap "Continue with Telegram".
2. Enter the phone number +1 555 010 0199 (type it with the +1, or pick United States
   and enter 5550100199), then tap Continue.
3. Enter the code 24680.
4. Choose whether to allow Photos access (either works), then tap "Start using Lelvo".
A demo library with sample photos and videos loads, marked by a banner at the top. Every
feature works: timeline, pinch to resize, viewer, video playback, selection, sharing,
albums, settings. On the Backup tab, "Back up now" shows a simulated backup of 6 items.
In demo mode nothing is uploaded and no Telegram connection is made.

REAL FLOW: signing in with a real number sends the login code to that account's Telegram app.
A video of the real sign-in and backup is here: <link>

Telegram allows third-party apps through its API (https://core.telegram.org/api/terms);
the app follows those terms (own api_id, disclosure on the welcome screen). Each user signs in
with their own existing Telegram account and stores only their own photos in a private channel
they own. The app doesn't sell or offer storage, doesn't create Telegram accounts, writes only
to the user's own library channel, and follows Telegram's upload limits.

Background modes: "processing" and "fetch" are used to continue the user-started photo backup.
```

- [ ] 📝 Fill in contact name, phone and email in App Review Information, and answer within hours while in review.

---

## Phase 3 — Technical requirements

### 3.1 Privacy manifest (required; upload is rejected or flagged without it) 🔧

✅ Added: `iOS/Resources/PrivacyInfo.xcprivacy` and `macOS/Resources/PrivacyInfo.xcprivacy` (no tracking; phone number, photos and videos, and user ID as collected data, see Phase 5.3; UserDefaults `CA92.1`, file timestamps `C617.1` + `3B52.1`, disk space `E174.1`). TDLibFramework ships
no manifest of its own and calls `stat`/`statfs`, which the app manifest covers. What it declares:

- ✅ Privacy manifest with:
  - `NSPrivacyTracking` = false, `NSPrivacyTrackingDomains` = []
  - `NSPrivacyCollectedDataTypes` = phone number, photos or videos, user ID (linked, not tracking, app functionality)
  - `NSPrivacyAccessedAPITypes`:
    - `NSPrivacyAccessedAPICategoryUserDefaults` — reason `CA92.1` (app's own settings)
    - `NSPrivacyAccessedAPICategoryFileTimestamp` — reason `C617.1` (files in the app container), plus `3B52.1`
      if timestamps of user-picked files are read
    - `NSPrivacyAccessedAPICategoryDiskSpace` — reason `E174.1` (check space before downloads/exports), only if
      the app reads free disk space
    - `NSPrivacyAccessedAPICategorySystemBootTime` — reason `35F9.1`, only if `systemUptime` /
      `mach_absolute_time` is used
- ✅ TDLibKit / TDLibFramework ship no privacy manifest; the app's manifest covers their API use. Checked 3 November
      2026 on the arm64 framework: it imports `stat`, `fstat`, `lstat` and `statfs`, all covered. Boot time isn't
      declared because it doesn't import `mach_absolute_time`. Re-check after a TDLib update.
- [ ] 🧪 After archiving: Xcode Organizer → right-click archive → *Generate Privacy Report*, and check nothing is
      missing.

### 3.2 Background modes (2.5.4) 🧪

`UIBackgroundModes` = `fetch`, `processing`.

- ✅ `audio` and Picture in Picture are removed, so there's no background audio to justify. Don't add `audio` back
      without a real audio feature; silent-audio keep-alive is an instant rejection.
- [ ] ✅ `fetch` / `processing`: `BGAppRefreshTask` and `BGProcessingTask` are registered, and identifiers are listed in
      `BGTaskSchedulerPermittedIdentifiers`.
- [ ] 🧪 Backups must not keep the app alive by tricks (no silent audio, no fake location). Only BGTasks and
      `BGContinuedProcessingTask`.

### 3.3 Device support 🔧

`TARGETED_DEVICE_FAMILY = "1,2"` means you claim iPad support, so the reviewer may test on an iPad, and iPad
screenshots become mandatory.

- ✅ **iPhone only for v1:** `TARGETED_DEVICE_FAMILY: "1"` in `project.yml`, so no iPad screenshots are needed.
- [ ] 🧪 Reviewers still run iPhone apps on iPad in compatibility mode: open the app once on an iPad simulator and
      check nothing crashes or looks broken.

### 3.4 Build hygiene 🔧🧪

- ✅ SDK: uploads need Xcode 26 or later with the iOS 26 SDK or later (since 28 April 2026). CI picks the newest stable
      Xcode on the runner; check the version in the run log. Apple announces new minimums for April 2027.
- ✅ Version and build number: set by the Release workflow (version you enter, build = run number, always increasing) for every
      upload.
- ✅ Release builds don't expose debug features: `-UITestReset`, `-UITestDemoLibrary`, `-autoScrollTest`,
      `-verifyCloudReads*` and `-clearCacheTest` are compiled only in Debug (`#if DEBUG`).
- ✅ No placeholder text, "TODO", "beta", "coming soon", sideloading, Android or donation text in the app's Swift
      strings (searched 3 November 2026). Repeat the search before submitting, and 🧪 tap every button on the final build.
- ✅ Settings → About links the **Privacy Policy** ([PRIVACY.md](../PRIVACY.md)), the FAQ and issue reporting.
- ✅ Settings offers **Sign out and reset**, which ends the Telegram session and removes the app's data from the device
      (also the "revoke credentials" mechanism 5.1.1(v) asks of social network sign-in).
- ✅ Account deletion (5.1.1(v)) isn't required because the app never creates Telegram accounts: a number with no
      account stops at "No Telegram account" and sends the user to Telegram's app (`.noAccount` step in
      `OnboardingView.swift`). If the reviewer asks, link Telegram's deletion page (https://my.telegram.org/delete).
- ✅ Consent before data leaves the device (5.1.2(i)): the phone screen says the number goes only to Telegram; automatic
      backup is off by default, so uploads start only when the user asks.

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

The app bundles encryption beyond Apple's: TDLib/MTProto via OpenSSL, plus AES-GCM and Argon2 for encrypted libraries.
These are standard or published algorithms, and Apple's definition of non-standard covers only ones that are neither
adopted by a standards body nor published. [Apple's table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption):

| Encryption | Documents Apple asks for |
|---|---|
| Only what's in Apple's OS | None |
| **Standard algorithm not provided by Apple's OS (Lelvo)** | French declaration, only if sold in France |
| Proprietary, not accepted by standards bodies | US CCATS, plus the French declaration if sold in France |

- [ ] 📝 **Decided: France is left out of v1.** Switch it off in App Store Connect → Pricing and Availability. `ITSAppUsesNonExemptEncryption = false` skips the questions, so
      App Store Connect won't remind you. France controls secure storage and secure communications apps, and Lelvo is
      both. To add France later: file the declaration with ANSSI, upload it, and put the code Apple gives you in
      `ITSEncryptionExportComplianceCode` (the key then becomes `true`).
- [ ] 📝 Apple holds the developer responsible for this answer, and says exempt encryption may need a yearly
      self-classification report to the US government. Law-firm summaries of the March 2021 rule say most mass-market
      software no longer files it, so a consumer app like Lelvo probably doesn't, but components and toolkits differ.
      That's a reading of summaries, not advice: confirm on the
      [BIS mass market page](https://www.bis.gov/learn-support/encryption-controls/mass-market) or with a specialist.
- [ ] 📝 If App Store Connect asks for documentation anyway, follow its prompts. Don't change the Info.plist answer
      to hide encryption.

---

## Phase 4 — Privacy policy and support pages ✅

Both are live (Cloudflare, deployed on every push to main):

- **Privacy Policy URL:** https://lelvo.mshahilkv.workers.dev/privacy (built from [PRIVACY.md](../PRIVACY.md) by
  `Scripts/website-pages.py`; the app's About screen links here).
- **Support URL:** https://github.com/shahil-kv/Lelvo/blob/main/SUPPORT.md (contact email, FAQ, how to report a
  problem).
- **Marketing URL:** https://lelvo.mshahilkv.workers.dev

Replace these with `lelvo.app` addresses once the domain is live.

- ✅ The policy covers what 5.1.1(i) lists: who we are, what's collected, how it's used, who receives it, how long it's
  kept, how to delete it and how to stop sharing. Apple also asks you to confirm third parties give equal protection.
  Telegram is the only one, and its own policy applies, so the policy says that plainly instead of promising on its
  behalf.
- [ ] 🧪 Open all three URLs while signed out of GitHub and on a phone, right before submitting.

---

## Phase 5 — App Store Connect setup 📝

### 5.1 Create the app

- [ ] Register the bundle ID `app.lelvo.ios` in developer.apple.com → Identifiers. Enable only the
      capabilities the app uses (Background Modes are Info.plist-only; no Push, no iCloud unless used).
- [ ] App Store Connect → My Apps → **+** → New App: platform iOS, name Lelvo, primary language, bundle ID, SKU
      (e.g. `lelvo-ios-1`).
- [ ] Separate Mac app (`app.lelvo.mac`): a separate submission later with its own checklist run
      (sandbox entitlements, notarization not needed for the Mac App Store). Ship iOS first.

### 5.2 App information

- [ ] Category: **Photo & Video** (secondary: Utilities).
- [ ] Content rights: answer **yes, it contains third-party content, and I have the rights**. The demo library bundles
      Unsplash photos ([NOTICE.md](../NOTICE.md)) and the app accesses Telegram under its API terms.
- [ ] **Age rating** (new questionnaire, required since 31 January 2026): "None" or "No" for everything: parental
      controls, age assurance, user-generated content (no broad distribution), social media (no feed), messaging and
      chat (users can't message each other in the app), advertising, unrestricted web access (links open in the
      browser). Expected result: 4+.
- [ ] Price: Free. Availability: all countries **except France** (3.6).
- [ ] **EU trader status** (Digital Services Act): App Store Connect asks when you submit a new app, and it's required
      to be sold in the EU. You must decide this yourself. A trader's address, phone and email appear publicly on the EU
      product page, so use a P.O. box and a separate number if you can. As a non-trader, EU users are told consumer
      rights don't apply. Plan for trader status once paid Plus ships. Or leave the EU out of v1.
- [ ] No in-app purchases, no ads, no external payment or donation links in the app (3.1.1). A "donate" link in the
      app would need In-App Purchase; leave it out of v1.

### 5.3 App Privacy ("nutrition label")

Apple defines "collect" as sending data off the device so that "you and/or your third-party partners" can access it for
longer than the request needs, and "third-party partners" includes "third-party SDKs ... whose code you've added".
TDLib is Telegram's code, and Telegram keeps the phone number and the backups. So **"Data Not Collected" isn't a safe
answer**, even though you receive nothing.

- ✅ Decided: declare the data. `PrivacyInfo.xcprivacy` (iOS and Mac) already lists the same three types.
- [ ] Enter these in App Store Connect, all **App Functionality**, **linked to the user**, **not used for tracking**:
      - Contact Info → Phone Number
      - User Content → Photos or Videos
      - Identifiers → User ID (the Telegram account)
- [ ] Say in the description and notes that this data goes only to the user's own Telegram account and that the
      developer receives none of it. The privacy policy's "What we collect: Nothing" stays true of the developer.
- [ ] Privacy policy URL from Phase 4.

### 5.4 Store listing text (Guideline 2.3 — accurate metadata)

Rules:
- No "unlimited", "free forever", or "never lose" claims about Telegram storage (2.3.1). Telegram's limits and
  terms are not yours to promise.
- No mention of Android or other platforms (2.3.10).
- No "Telegram" in the name, subtitle or keywords (trademark). In the description, factual use only.
- Describe a backup to the user's own account, never free or unlimited storage (5.2.2).
- Telegram API terms 2.2: the description must say prominently that the app uses the Telegram API and is part of the
  Telegram ecosystem, so it goes first. Don't move it to the end.
- No mention of other apps' names as keywords (Google Photos, iCloud…) (2.3.7).

Templates to adapt:

- **Subtitle (30 chars):** `Back up photos to your channel`
- **Keywords (100 chars):** `photo backup,video backup,gallery,private,encrypted,restore,cloud,timeline,albums,storage`
- **Promotional text:** `Back up your photo library to a private channel in your own account, and browse it in one timeline.`
- **Description:**
  ```
  Lelvo uses the Telegram API and is part of the Telegram ecosystem. It is not made by,
  affiliated with or endorsed by Telegram. You need a Telegram account.

  Back up your photos and videos to a private channel in your own Telegram account, and
  browse your whole library in one fast timeline.

  • Original quality backups of photos, Live Photos and videos
  • One timeline for photos on this iPhone and in your backup
  • Stream backed-up videos without downloading them first
  • Optional end-to-end encryption with your own passphrase
  • Restore everything on a new iPhone by signing in
  • Background backup that continues where it left off

  Your data stays yours: the app has no servers, no accounts of its own, no analytics and
  no ads. Photos go directly from your iPhone to your own Telegram account, and we never
  receive them.

  Storage in your Telegram account is subject to Telegram's terms.
  ```
- [ ] Copyright: `2026 <Your Legal Name>` (the name on your Apple Developer account).
- [ ] Support URL, Privacy URL, (Marketing URL).

### 5.5 Screenshots

- [ ] iPhone **6.9"** (1320 × 2868 or 1290 × 2796), 3–10 images. Apple scales them for smaller iPhones.
- [ ] Use real app screens (2.3.3), and use demo-library photos (Unsplash license). No real people's faces without permission,
      no Telegram logo, and no device frames showing other brands.
- [ ] Suggested set: timeline · viewer · backup progress · encrypted library setup · restore screen.
- [ ] Optional App Preview video (15–30 s, real screen recording).

---

## Phase 6 — TestFlight dry run 🧪

External TestFlight goes through a light Beta App Review. It's the cheapest way to catch problems before the real
review.

- [ ] Upload: Actions → Release (with the App Store Connect secrets set, it signs and uploads automatically; see
      the workflow above), or Xcode → Product → Archive → Distribute → App Store Connect → Upload. The CI upload has
      never run, so if it fails, use Xcode for the first build and fix CI afterwards.
- [ ] Every Release run also publishes an unsigned IPA on GitHub, with the built-in Telegram keys inside. Use the new
      app-account keys from Phase 0 before running it.
- [ ] Fix any email from App Store Connect after upload (ITMS-9xxxx warnings: privacy manifest, missing usage
      strings, icons).
- [ ] Internal testing on your own iPhone: run the whole Phase 3.5 list on the TestFlight build.
- [ ] External testing: after the demo approval (Phase 2.1), add 2–5 testers and submit for Beta App Review with the same demo notes (Phase 2.3). Approval
      here is a strong sign the main review will pass.
- [ ] Ask testers to try: fresh sign-in, backup of 500+ items, restore on another device, encrypted library.

---

## Phase 7 — Submit for review 📝

- [ ] Select the TestFlight build on the version page.
- [ ] Fill in "What's New" for v1 ("First release.").
- [ ] App Review Information: demo instructions (2.3), contact details, attach the real-flow video link.
- [ ] Release option: **Manually release this version**, so you control the launch moment.
- [ ] Submit. Apple reviews 50% of submissions in under 24 hours and 90% in under 48 hours.
- [ ] Watch email and App Store Connect → *Resolution Center*. Reply politely and specifically within a day.

---

## Phase 8 — If it gets rejected

A rejection isn't final. Apple emails you, and App Store Connect shows the guideline number and details. Reply there,
fix the issue and resubmit; each resubmission is reviewed again. A listing-only fix needs no new build. If you believe
the reviewer misunderstood the app, you can appeal once per rejected submission.

| Rejection | What it means | Fix / reply |
|---|---|---|
| **2.1 Information Needed / can't sign in** | Reviewer couldn't get in, or wants a real demo account | Point to the demo number, the code and Apple's prior approval (case number); check demo mode works on the build under review; re-send the video link. |
| **5.1 Privacy label mismatch** | Label doesn't match what the app sends | Declare phone number and photos as in Phase 5.3. Metadata only, no new build. |
| **2.1 App Completeness — crash** | Crash on their device | Get the crash log from App Store Connect → TestFlight → Crashes; often IPv6-only network or iPad. Fix, upload a new build. |
| **2.3.x Metadata** | Claims, keywords, screenshots | Remove "unlimited", the Telegram name from keywords, or Android mentions. Metadata-only fixes don't need a new build. |
| **4.1 Copycat / 5.2.1 Intellectual Property** | Name or icon looks like Telegram, Apple Photos or upstream | Rename, redraw the icon. Reply that the Telegram API terms allow third-party clients (link). |
| **5.2.2 Third-party service** | "Do you have permission to use Telegram?" | Reply: Telegram's API is public and free for third-party apps under https://core.telegram.org/api/terms; the app uses its own registered api_id and complies (disclosure on the welcome screen). Each user stores only their own photos in their own account, and the app sells no storage. Lead with the terms, not other apps: Swiftgram is a messaging client, and CloudVault (a Telegram channel storage app on the App Store) uses a bot, so neither is the same case or proof of Telegram's permission. |
| **5.1.1 Privacy policy / permissions** | Missing policy link in app, or permission purpose strings too vague | Add the in-app link; make `NSPhotoLibraryUsageDescription` specific (it already is). |
| **5.1.1(v) Account deletion** | Reviewer thinks the app creates accounts | Reply: the app never creates accounts; users sign in with an existing Telegram account, deletable at https://my.telegram.org/delete; the app offers sign-out and on-device data removal. |
| **4.2 Minimum functionality** | Rare | Point out the backup engine, encryption, restore and streaming: it's a full app, not a web wrapper. |

If a reply doesn't help, you can appeal to the App Review Board (App Store Connect → Resolution Center → appeal).

---

## Phase 9 — After approval

- [ ] Release manually.
- [ ] Watch crashes in Xcode Organizer → Crashes for the first week.
- [ ] Keep the Telegram app account (Phase 0) active. Telegram deletes accounts that stay offline for a set time;
      set *Settings → Privacy and Security → Delete my account → If away for* to the maximum, and open the app now
      and then.
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
| New app name | ✅ Lelvo |
| Original icon | ✅ Phase 1.2 |
| `lelvo.app` bought, links updated | ⬜ not required by Apple; do before the first submitted build |
| Reviewer demo mode (Release build, real sample media) | ✅ Phase 2.1 · ⬜ test on TestFlight |
| Apple's prior approval of the demo mode | ⬜ Phase 2.1 |
| No Picture in Picture, no `audio` background mode | ✅ Phase 3.2 |
| Privacy manifests list phone number, photos, user ID | ✅ Phase 5.3 · ⬜ enter the same in App Store Connect |
| France left out | ✅ decided · ⬜ switch off in App Store Connect (Phase 3.6) |
| EU trader status decided | ⬜ Phase 5.2 |
| PrivacyInfo.xcprivacy (iOS and Mac) | ✅ Phase 3.1 |
| iPhone-only or full iPad support decision | ✅ iPhone only (Phase 3.3) |
| Privacy policy link + sign-out & remove data in Settings | ✅ Phase 3.4 |
| Privacy policy + support pages | ✅ live (Phase 4) |
| TestFlight upload from CI | ✅ workflow ready · ⬜ App Store Connect secrets (step 6 of the workflow) |
| App Store Connect listing, privacy label, screenshots | ⬜ Phase 5 |
| TestFlight external beta passed | ⬜ Phase 6 |
