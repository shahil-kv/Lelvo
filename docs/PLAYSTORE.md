# Google Play Store release checklist (Android)

Step-by-step list of everything to fix, prepare and submit so Google Play approves the Android app (`app.lelvo.android`)
on the first try. Work top to bottom; each phase depends on the ones before it. Tick boxes as you go.

No checklist can guarantee approval: Play Console uses both automated scanners and human reviewers, and policies change.
This guide covers every known policy and technical requirement that applies to Lelvo for Android, as of November 2026.
Re-read the current [Google Play Developer Policy Center](https://play.google.com/about/developer-content-policy/) before
submitting.

Legend: ✅ already done in the code · 🔧 code or CI change needed · 📝 paperwork / Play Console · 🧪 testing

---

## Testing tracks: Internal → Closed → Production

Google Play uses staged tracks. You upload one signed **Android App Bundle (`.aab`)** and promote that same build
across tracks.

| | Internal testing | Closed testing | Production |
|---|---|---|---|
| Who can install | Up to 100 testers by email list | Invited testers (email list or Google Group) | Everyone on Google Play |
| Google review | None (usually live in minutes) | Full policy & technical review | Full policy & technical review |
| Mandatory gate | None | **Personal accounts created on or after 13 Nov 2023:** at least **12 testers opted in for 14 continuous days** before applying for Production | Unlocked only after Closed testing passes (for affected personal accounts) |
| Builds | `.aab` signed with upload key | Same `.aab` promoted from Internal | Same `.aab` promoted from Closed |

**Organization vs. Personal account:** Organization accounts (verified with a D-U-N-S number) are exempt from the
12-testers / 14-days closed testing rule. Personal accounts created on or after 13 November 2023 must complete it before
Production access opens.

**Timing:** Initial reviews for new apps typically take 3–7 days (sometimes longer for sensitive permission declarations).
If you need the 14-day closed test, plan at least 3–4 weeks from first upload to public launch.

---

## The four things most likely to block approval (remaining)

1. **Photo and Video Permissions policy (`READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`)** (Phase 3.2). Google rejects apps
   that request broad media permissions instead of the Android Photo Picker unless the app's core purpose requires broad
   access. Cloud photo backup and gallery apps qualify, but you must complete the **Photo and Video Permissions
   Declaration** in Play Console with a clear explanation.
2. **Foreground Service (`FOREGROUND_SERVICE_DATA_SYNC`) declaration + video** (Phase 3.3). Play Console requires a
   declaration and a short screen recording proving the foreground notification is visible during user-started backups.
3. **App Access / Demo mode instructions** (Phase 2). Reviewers cannot receive a Telegram SMS/app login code. You must
   enter the demo phone number (`+1 555 010 0199`) and code (`24680`) in Play Console → *App content → App access*.
4. **Telegram's disclosure and naming rules** (Phase 1.2, 5.4). Keep the Telegram API disclosure at the top of the store
   description, and never put "Telegram" in the app title, icon or feature graphic.

*(Fixed on this branch: stripped hidden `ACCESS_COARSE_LOCATION` / `ACCESS_FINE_LOCATION` merged from MapLibre, added
`.aab` + `mapping.txt` output to `.github/workflows/android-release.yml`, added MapLibre & ML Kit to `ACKNOWLEDGEMENTS`
and `NOTICE.md`, and aligned `PRIVACY.md` with the disabled ML Kit telemetry backend.)*

---

## Codebase audit summary (28 November 2026)

Verified by manual audit + `sunvali/play-store-review-skill` (`scan_android.py`, 0 errors, 0 leaked secrets):

| Check | Status | Details |
|---|---|---|
| Package ID | ✅ | `app.lelvo.android` (`android/app/build.gradle.kts`) |
| `targetSdk` / `minSdk` | ✅ | `targetSdk = 36` (Android 16), `compileSdk = 37`, `minSdk = 29` — meets the 31 Aug 2026 Play target API 36 rule |
| 16 KB memory page size | ✅ | Verified all 6 `arm64-v8a` `.so` libraries (`libtdjni.so`, `libmaplibre.so`, `libmlkitcommonpipeline.so`, `libargon2jni.so`, `libargon2native.so`, `libandroidx.graphics.path.so`): all `PT_LOAD` segments aligned to `0x4000` (16 KB) |
| Hidden merged permissions | ✅ | Fixed: `ACCESS_COARSE_LOCATION` and `ACCESS_FINE_LOCATION` stripped via `tools:node="remove"` in `AndroidManifest.xml`; verified absent in merged manifest |
| Advertising ID (`AD_ID`) | ✅ | Not present in merged manifest |
| `READ_EXTERNAL_STORAGE` | ✅ | Capped with `android:maxSdkVersion="32"` |
| Android 14+ partial photo access | ✅ | `READ_MEDIA_VISUAL_USER_SELECTED` declared |
| `FOREGROUND_SERVICE_DATA_SYNC` | ✅ / 📝 | Declared on WorkManager's `SystemForegroundService`; 6-hour Android 15+ timeout handled in `BackupWorker.kt`. Needs Play Console declaration + video |
| ML Kit telemetry blocker | ✅ | `CctBackendFactory` removed in `AndroidManifest.xml`; `PRIVACY.md` updated to match |
| Reviewer demo mode | ✅ | Built in `DemoMode.kt` (`+15550100199` / `24680`), shares `iOS/DemoLibrary` as assets |
| Debug tools gating | ✅ | `onCoreCheck`, `onBackgroundLab`, `onScrollLab`, and `debugMessage` intent hooks are gated behind `BuildConfig.DEBUG` |
| R8 shrinking / obfuscation | ✅ | `isMinifyEnabled = true` in release (satisfies upcoming Feb 2027 code optimization threshold) |
| Monetization / Pro | ✅ | `ProStore.OFFERED = false` — no unfinished Pro UI, no external payment or donation links (note: use Play Billing Library 8+ when Pro ships) |
| Donation page reachable from the app | ✅ | Fixed 28 Nov: the privacy page linked "Support" (card/UPI contributions) 3 times. Play's Payments policy allows donations outside Play Billing only for tax-exempt charities (Apple 3.1.1 likewise). `Scripts/website-pages.py` now builds `privacy.html` bare (`BARE`): no menu, footer links or home link, and it fails if a `support` link survives. ⚠️ The in-app GitHub link still reaches the README's Support badge and the repository's Sponsor button (`.github/FUNDING.yml`): see Phase 4 |
| Telegram API disclosure in-app | ✅ | Shown prominently in `IntroScreen.kt` and `HelpScreens.kt` (About) |
| Privacy policy link in-app | ✅ | `AboutScreen` links `https://lelvo.app/privacy`; the page mentions Google Play's Data safety section and the Android Keystore |
| Sign out & local data reset | ✅ | `SettingsScreen.kt` → "Sign out and reset this phone" |
| Open-source acknowledgements | ✅ | Fixed: **MapLibre Native** and **Google ML Kit** added to `HelpScreens.kt` and `NOTICE.md` |
| Release artifact format | ✅ | Fixed: `.github/workflows/android-release.yml` now builds both `.apk` and Play Store `.aab` + `mapping.txt` (`lelvo-android-play` artifact) |
| In-app intro screenshots | 🔧 (optional) | `IntroScreen.kt` (`drawable-nodpi/feature_*.jpg`) currently uses iPhone 17 Pro screenshots; replace with Android screenshots when convenient |

### Upcoming Play Console deadlines to watch (2026–2027)

- **In force now (Nov 2026):** Package registration / developer verification in Play Console, and trader status
  declaration (check Play Console Home for prompts).
- **Feb 2027:** Hard enforcement of 16 KB page size for updates (already passing ✅) and R8 code optimization for apps
  over 10 MB DEX (already enabled ✅).
- **Apr 2027:** Zero-tap sign-in restoration (Restore Credentials API) for apps with user sign-in — evaluate whether
  Telegram sessions qualify or request a Play Console exemption before April 2027.
- **When Lelvo Pro launches:** Use **Play Billing Library 8 or higher** (Library 9 required by 31 Aug 2027).

---

## Pre-submission compliance skills (installed & optional)

- ✅ **Installed in this repo:** [`play-store-review`](../.agents/skills/play-store-review/SKILL.md)
  (`sunvali/play-store-review-skill` v2.2.3). Run its offline scanner any time before a release:
  ```bash
  python3 -B .agents/skills/play-store-review/scripts/scan_android.py android --output /tmp/lelvo-play-scan.json
  ```
  *(Pass `--artifact dist/Lelvo-<version>.aab` once built to audit the release bundle directly.)*
- **Optional companion skills:**
  - `tamtom/gplay-cli-skills` (`npx skills add tamtom/gplay-cli-skills`) — Play Console CLI automation for uploading
    `.aab` builds, screenshots, and reading Android Vitals.
  - Google's official `android/skills` (`play-policy-insights`) — deep data-flow tracing for Data Safety and restricted
    permissions.

---

## Your workflow, start to finish

### Stage A — Codebase blockers (completed on `docs/play-store-release`)

- [x] 1. ✅ Strip `ACCESS_COARSE_LOCATION` and `ACCESS_FINE_LOCATION` in
      `android/app/src/main/AndroidManifest.xml` using `tools:node="remove"`, and verified merged manifest.
- [x] 2. ✅ Add **MapLibre Native** (BSD-2-Clause) and **Google ML Kit** (Google APIs Terms of Service) to
      `ACKNOWLEDGEMENTS` in `android/app/src/main/kotlin/app/lelvo/android/settings/HelpScreens.kt` and `NOTICE.md`.
- [x] 3. ✅ Add `.aab` (`./gradlew :app:bundleRelease`) output and `mapping.txt` artifact upload (`lelvo-android-play`)
      to `.github/workflows/android-release.yml`.
- [x] 4. ✅ Update `PRIVACY.md` lines 52–55 to match `CctBackendFactory` removal in `AndroidManifest.xml`.

### Stage B — Accounts and keys

- [ ] 5. 📝 Create a [Google Play Console](https://play.google.com/console) developer account ($25 one-time fee). Complete
      identity verification (government ID + address; D-U-N-S number if registering as an Organization).
- [ ] 6. 📝 Decide on the Telegram `api_id` / `api_hash` for Android (Phase 0). Use a dedicated app Telegram account, not
      a personal account.
- [ ] 7. 📝 Decide on **Play App Signing** key strategy (Phase 3.5):
      - If you want users who sideloaded the GitHub APK to update smoothly from Google Play, enroll using your existing
        release keystore as the app signing key (or export it with PEPK) and generate a separate upload key.
      - Otherwise let Google generate a new Play App Signing key and use your keystore as the upload key (GitHub APK
        users will need to uninstall and reinstall from Play once).
- [ ] 8. 📝 Confirm every merged contributor has signed [CLA.md](../CLA.md) (check the `cla-signatures` branch).

### Stage C — Play Console app setup & declarations

- [ ] 9. 📝 Create the app in Play Console: App name `Lelvo: Photo Backup` (or `Lelvo` if available; 30 chars max),
      default language, **App** (not Game), **Free**.
- [ ] 10. 📝 Complete all items under **App content** (Phase 5):
      - Privacy policy URL (`https://lelvo.app/privacy`)
      - Ads: **No, my app does not contain ads**
      - App access: **All or some functionality is restricted** → provide Demo Mode credentials (`+1 555 010 0199` /
        `24680`) and instructions (Phase 2)
      - Content ratings (IARC questionnaire — expected: Everyone / PEGI 3)
      - Target audience: **13–15, 16–17, 18 and over** (not directed at children under 13)
      - News apps: **No**
      - COVID-19 / Health / Government / Financial features: **None**
      - **Data safety** form (Phase 5.3)
      - **Advertising ID**: **No**
      - **Photo and Video Permissions** declaration (`READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`) (Phase 3.2)
      - **Foreground Service Permissions** declaration (`dataSync` + video link) (Phase 3.3)
- [ ] 11. 📝 Fill in the **Main store listing** (Phase 5.4): short description (80 chars), full description (Telegram
      disclosure first), app icon (512 × 512 PNG), feature graphic (1024 × 500 PNG), and 4–8 Android phone screenshots.
- [ ] 12. 📝 Set Store settings: Category **Photography** (or Tools), contact email (`support@lelvo.app`), website
      (`https://lelvo.app`).

### Stage D — Internal testing (no Google review)

- [ ] 13. 🔧 Build a signed release `.aab` (`./gradlew :app:bundleRelease`) and upload it to the **Internal testing**
      track along with `mapping.txt` (R8 deobfuscation).
- [ ] 14. 🧪 Inspect Play Console's **Pre-launch report** (automated Firebase Test Lab crawl across real Android
      devices) for crashes, ANRs, accessibility issues, and security warnings.
- [ ] 15. 🧪 Install from Play Store (Internal testing link) on a real Android phone and run the full test checklist
      (Phase 3.6):
      - Clean install → Demo Mode (`+1 555 010 0199` / `24680`) → every tab, viewer, video playback, simulated backup.
      - Real Telegram sign-in → create encrypted library → back up photos/videos → verify in Telegram → reinstall &
        restore.
      - Permissions: denied, limited ("Select photos and videos"), full, and revoking mid-use.
      - Background backup & foreground notification (verify notification appears and Pause works).
      - Airplane mode / offline recovery, kill mid-backup, dark mode, large font scale, TalkBack basics.

### Stage E — Closed testing (required for new Personal accounts)

- [ ] 16. 📝 Record the short foreground-service demo video (showing backup progress notification) and the 1–2 minute
      real-flow video (sign-in → backup → Telegram channel → restore), and link them in Play Console declarations.
- [ ] 17. 📝 Promote the verified `.aab` from Internal testing to **Closed testing**.
- [ ] 18. 🧪 If on a Personal account created on/after 13 Nov 2023: recruit **at least 12 testers** (aim for 15–20 in
      case someone opts out) and keep them opted in for **14 continuous days**. Have testers actually open and use the
      app and leave feedback.
- [ ] 19. 📝 Answer Google's Production access questionnaire honestly after the 14 days (how testers were recruited,
      what feedback you received, what you fixed).

### Stage F — Submit to Production

- [ ] 20. 🧪 Final pre-flight check:
      - No `ACCESS_COARSE_LOCATION` / `ACCESS_FINE_LOCATION` in the uploaded `.aab`'s merged manifest.
      - All `.so` libraries pass 16 KB alignment (Play Console also validates this on upload).
      - Demo Mode works on this exact `.aab` build.
      - Data Safety form, Privacy Policy (`https://lelvo.app/privacy`), and actual network behavior agree.
      - Store listing has no "unlimited", "free storage", "never lose", or iPhone/iOS mentions.
      - All screenshots are real Android screens with demo-library photos and no Telegram logo.
- [ ] 21. 📝 Promote the `.aab` to **Production** (consider starting with a staged rollout, e.g. 20% → 50% → 100%, or
      turn on **Managed publishing** so you control the exact release moment).

### Stage G — After approval

- [ ] 22. 🧪 Monitor **Android Vitals** (crashes, ANRs, excessive wakeups) daily for the first week.
- [ ] 23. 📝 Keep the Telegram app account active (set *If away for* to the maximum) and keep Demo Mode working in every
      future release.

---

## Phase 0 — Accounts and keys

- [ ] 📝 **Google Play Console** ($25 one-time registration fee) at https://play.google.com/console.
- [ ] 📝 **Telegram API key (`api_id` / `api_hash`).** Create or reuse a dedicated app key on a spare Telegram account at
      https://my.telegram.org → *API development tools* (platform: Android). Never use your personal Telegram account.
      Keep the keys only in `android/local.properties` (git-ignored) and GitHub Actions secrets (`TD_API_ID`,
      `TD_API_HASH`).

---

## Phase 1 — Legal and policy blockers

### 1.1 License: GPL-3.0 + CLA ✅

- ✅ Google Play does not impose Apple's DRM usage restrictions, and Lelvo already enforces [CLA.md](../CLA.md) on
  contributions.
- ✅ `AboutScreen` in `HelpScreens.kt` states GPL-3.0 and links to the source repository.
- [ ] 🔧 Update `ACKNOWLEDGEMENTS` in `android/app/src/main/kotlin/app/lelvo/android/settings/HelpScreens.kt` to include
      **MapLibre** (BSD-2-Clause) and **Google ML Kit** (Google APIs Terms of Service).

### 1.2 Name, icon and Telegram API terms (https://core.telegram.org/api/terms)

- ✅ App icon is original artwork; no Telegram logo or paper plane symbol (terms 2.4).
- ✅ In-app disclosure is prominently displayed on the intro screen (`IntroScreen.kt`) and in About (`HelpScreens.kt`)
  (terms 2.2).
- [ ] 📝 Never use "Telegram" in the Play Store app title (30 chars max), developer name, icon, or feature graphic
      (terms 2.3; Google Play Impersonation policy). Factual mention in the description is allowed.
- [ ] 📝 Put the Telegram API disclosure at the very top of the Play Store full description (Phase 5.4).
- [ ] 📝 Watch the app Telegram account's messages and email: Telegram gives 10 days to address a reported violation
      before revoking API access or requesting store removal (terms 4.2).
- [ ] 📝 **Before Lelvo Pro launches:** use **Google Play Billing Library** for all digital subscriptions/unlocks (Google
      Play Payments policy), and list all monetization methods in the Play Store description (Telegram API terms 3.2).

---

## Phase 2 — Reviewer sign-in (Play Console → App Access)

Google Play rejects apps under **Broken Functionality** or **App Access** if a reviewer cannot sign in.

### 2.1 Built-in Demo Mode ✅

Already implemented in `android/data/src/main/kotlin/app/lelvo/data/DemoMode.kt` (works in Release builds):

- Phone number: `+1 555 010 0199` (fictional 555-01xx range; never contacts Telegram).
- Code: `24680`.
- Loads the bundled sample library (`iOS/DemoLibrary` packaged as Android assets), with working timeline, viewer, video
  playback, collections, search, settings, and simulated backup of pending items.

### 2.2 Instructions to paste into Play Console → App content → App access 📝

Select **All or some functionality in my app is restricted**, click **Add instructions**, and enter:

- **Name:** `Reviewer Demo Account`
- **Username / Phone:** `+1 555 010 0199`
- **Password / Code:** `24680`
- **Any other information:**
  ```
  Lelvo backs up photos and videos to a private channel in the user's own Telegram account using
  the official Telegram API (TDLib). We run no servers of our own. Because real Telegram sign-in
  requires a one-time code sent to that account's Telegram app or SMS, we provide a built-in demo
  mode with a full sample library:

  1. Tap through the intro screens and grant or deny Photos permission (both work).
  2. On the sign-in screen, enter phone number +1 555 010 0199 and tap Continue.
  3. Enter verification code 24680.
  4. The demo library opens with a banner at the top. You can test the timeline, photo viewer,
     video playback, collections, search, settings, and simulated backup ("Back up now" on the
     Backup tab). Nothing is uploaded in demo mode.

  Real-flow video (real Telegram sign-in, backup, Telegram channel verification, and restore):
  <insert unlisted YouTube or Drive link>
  ```

---

## Phase 3 — Technical & Play policy requirements

### 3.1 Merged manifest permissions 🔧

Audit result from `android/app/build/intermediates/merged_manifests/`:

- **Expected permissions (keep):**
  - `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`
  - `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_VISUAL_USER_SELECTED`, `READ_EXTERNAL_STORAGE` (`maxSdkVersion="32"`)
  - `ACCESS_MEDIA_LOCATION` (EXIF GPS metadata in photos for Places map)
  - `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`
  - `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED` (from WorkManager)
- **Unexpected permissions (REMOVE):**
  - `ACCESS_COARSE_LOCATION` and `ACCESS_FINE_LOCATION` are merged from MapLibre. Lelvo does **not** use live device GPS.
  - Add these lines inside `<manifest>` in `android/app/src/main/AndroidManifest.xml`:
    ```xml
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" tools:node="remove" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" tools:node="remove" />
    ```
  - Rebuild and re-verify the merged manifest before uploading.

### 3.2 Photo and Video Permissions policy (`READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO`) 📝

Under Google Play's **Photo and Video Permissions policy**, apps targeting Android 13+ may only request
`READ_MEDIA_IMAGES` and `READ_MEDIA_VIDEO` if broad, continuous access to the device's media library is core to the app.

In Play Console → *App content → Photo and Video Permissions*:

- **Core functionality justification (adapt as needed):**
  > Lelvo is a photo and video backup and unified gallery app. Its core functionality is to continuously index the user's
  > on-device photo and video library, display local and cloud-backed-up items in one chronological timeline, detect new
  > photos for automatic background backup to the user's private Telegram channel, and identify already-backed-up items so
  > the user can safely free up device storage. The Android Photo Picker only supports one-time manual selection and cannot
  > observe new photos, match existing local items against backed-up items, or power a unified gallery timeline. Users can
  > still grant limited access or deny permission and browse their cloud library.

### 3.3 Foreground Service Permissions (`FOREGROUND_SERVICE_DATA_SYNC`) 📝

In Play Console → *App content → Foreground service permissions*:

- **Permission:** `FOREGROUND_SERVICE_DATA_SYNC`
- **Use case:** User-initiated upload of large photo and video libraries to the user's private Telegram channel so the
  backup continues reliably when the user switches apps, with a live progress notification and Pause button.
  Add to the description, because it's true and Google compares the declaration with the app's behaviour:
  *"If the user turns on automatic backup, Android 10 and 11 may run those backups with the same progress
  notification (WorkManager expedited work). On Android 12 and later, only a backup the user starts uses the
  foreground service."* (Code: `BackupWorker.userRun` calls `setForeground`; automatic runs are expedited WorkManager
  jobs, which Android 10–11 run as a foreground service through `getForegroundInfo`.)
- **Video requirement:** Attach a short screen recording (15–30 seconds) showing the user tapping **Back up now**,
  leaving the app, and the ongoing backup progress notification appearing in the Android status bar / shade.
- ✅ `BackupWorker.kt` already handles Android 15+'s 6-hour `dataSync` timeout (`STOP_REASON_FOREGROUND_SERVICE_TIMEOUT`).

### 3.4 Target SDK & 16 KB memory page size ✅

- ✅ `targetSdk = 36` (Android 16) in `android/app/build.gradle.kts` — satisfies Google Play's 2026 target API policy.
- ✅ 16 KB page size alignment: all 6 native `.so` libraries in `arm64-v8a` are aligned to `0x4000` (16 KB). Re-verify
  whenever updating TDLib, MapLibre, ML Kit, or argon2kt:
  ```bash
  # Inspect PT_LOAD alignment on every .so inside the built AAB/APK
  llvm-objdump -p android/app/build/intermediates/merged_native_libs/release/mergeReleaseNativeLibs/out/lib/arm64-v8a/*.so | grep -E "file format|LOAD"
  ```

### 3.5 App Bundle (`.aab`), Play App Signing & mapping files 🔧

- [ ] 🔧 Update `.github/workflows/android-release.yml` (or add a Play Store release job) to run:
      ```bash
      ./gradlew :app:bundleRelease --no-daemon -Plelvo.versionCode="$CODE" -Plelvo.versionName="$VERSION"
      ```
      Output: `android/app/build/outputs/bundle/release/app-release.aab` and
      `android/app/build/outputs/mapping/release/mapping.txt`.
- [ ] 📝 Upload `mapping.txt` alongside each `.aab` (or enable automatic upload via Play Console / Gradle) so Android
      Vitals crash stack traces are readable.
- [ ] 📝 Note on `abiFilters`: `build.gradle.kts` sets `ndk { abiFilters += "arm64-v8a" }` in `release`. Google Play
      accepts `arm64-v8a`-only apps (64-bit requirement satisfied; 32-bit-only phones are excluded automatically).

### 3.6 Device & stability testing checklist 🧪

Run all of these on the **signed release `.aab`** installed via Play Internal Testing:

- [ ] 🧪 Clean install → Demo Mode (`+1 555 010 0199` / `24680`): every tab, viewer, pinch zoom, video playback, albums,
      search, simulated backup, sign out & reset.
- [ ] 🧪 Real Telegram account: sign in, create encrypted library, save recovery key, back up photos & videos, verify in
      Telegram, reinstall and restore.
- [ ] 🧪 Permissions: denied, limited (Android 14+ "Select photos and videos"), full, and revoking permission in Android
      Settings while the app is installed.
- [ ] 🧪 Foreground backup notification: start backup, switch apps, confirm notification updates and Pause works.
- [ ] 🧪 Airplane mode mid-backup → back online: no crash, clear message, resumes cleanly.
- [ ] 🧪 Force-stop mid-backup and relaunch: resumes with no duplicate uploads.
- [ ] 🧪 Android 15/16 16 KB page-size emulator image: launch, sign in / demo mode, open map (MapLibre), run search
      labeling (ML Kit), unlock encrypted library (argon2kt), view video.
- [ ] 🧪 Dark mode, light mode, largest font/display size, TalkBack basics, predictive back gesture (`enableOnBackInvokedCallback`).

---

## Phase 4 — Privacy policy and support pages ✅

All links are live and match the iOS checklist:

- **Privacy Policy URL:** https://lelvo.app/privacy (built from [PRIVACY.md](../PRIVACY.md))
- **Support URL:** https://github.com/shahil-kv/Lelvo/blob/main/SUPPORT.md
- **Website:** https://lelvo.app
- **Support email:** `support@lelvo.app`

- [x] 🔧 `PRIVACY.md` matches the `CctBackendFactory` removal, names Play's Data safety section, and
      `website/privacy.html` is regenerated (28 November 2026).
- [x] 🔧 The privacy page has no path to the Support (donation) page (Payments policy). Keep `privacy` in `BARE` in
      `Scripts/website-pages.py`; any page the app opens must be bare.
- [x] 📝 **Accepted risk (28 November 2026):** the app's "Source code" link (`AppLinks.REPOSITORY`, GPL) opens the
      GitHub repository, whose README has a "Support · card / UPI" badge and a Sponsor button (`.github/FUNDING.yml`).
      Linking an open-source app's repository is common on Play, and Payments rejections target in-app donate buttons,
      so it stays. If Google ever cites the Payments policy: move the badge into SUPPORT.md, delete `FUNDING.yml`,
      and reply in Play Console (no new build needed).
- [ ] 🧪 Open `https://lelvo.app/privacy` on a phone while signed out of GitHub before submitting, after the website
      deploy: no menu, no Support link.

---

## Phase 5 — Play Console setup & store listing 📝

### 5.1 App content declarations

- **Privacy policy:** `https://lelvo.app/privacy`
- **Ads:** No
- **App access:** Restricted → Demo Mode instructions (Phase 2.2)
- **Content rating (IARC):** Complete questionnaire ("No" to violence, sexual content, user-to-user messaging inside the
  app, ads, IAP, location sharing with others). Expected: **Everyone / PEGI 3**.
- **Target audience:** 13 and older (do not check under 13; avoids Families Policy requirements).
- **Advertising ID:** No.

### 5.2 Account deletion policy

Google Play requires an account deletion flow **only if the app lets users create an account from within the app**.

- Lelvo **does not create accounts** (users sign in to an existing Telegram account; a number without a Telegram account
  is directed to Telegram).
- In Play Console → Data Safety, answer **No** to *"Does your app allow users to create an account?"*.
- If a reviewer asks about data deletion anyway:
  - Local device data is deleted via **Settings → Sign out and reset this phone** or uninstalling the app.
  - Cloud library data lives in the user's own Telegram channel (deletable in Telegram) and Telegram accounts are
    deletable at `https://my.telegram.org/delete`. Both are documented at `https://lelvo.app/privacy`.

### 5.3 Data safety form

Google Play defines "collection" as transmitting user data off the device — including via third-party SDKs (TDLib,
Android Geocoder, OpenFreeMap). Because TDLib sends your phone number, Telegram user ID, and backed-up photos/videos to
Telegram, **"No data collected" is not a safe answer**.

Recommended answers (verify against any new dependencies before submitting):

- **Does your app collect or share any of the required user data types?** → **Yes**
- **Is all of the user data collected by your app encrypted in transit?** → **Yes** (MTProto / HTTPS)
- **Data types (all: Collected, NOT Shared, Purpose: App functionality):**
  - **Personal info → Phone number** (Required for sign-in; sent only to Telegram)
  - **Personal info → User IDs** (Telegram account ID; sent only to Telegram)
  - **Photos and videos → Photos** (Optional, user-initiated backup; sent only to the user's own Telegram channel)
  - **Photos and videos → Videos** (Optional, user-initiated backup; sent only to the user's own Telegram channel)
  - **Location → Approximate location** (Optional; ~1 km rounded photo area sent to Android Geocoder for place names,
    and map viewport to OpenFreeMap)
- **Note on ML Kit:** Because `CctBackendFactory` is stripped in `AndroidManifest.xml`, ML Kit runs strictly on-device
  without uploading usage metrics. If you ever re-enable it, declare *App info and performance → Diagnostics*.

### 5.4 Store listing text

Rules (Google Play Metadata policy + Telegram API terms):

- Never claim "unlimited", "free storage forever", or "never lose".
- Never include "Telegram" in the app title (30 chars max) or short description if avoidable; keep factual mention in
  the full description.
- Keep the Telegram API disclosure at the **very top** of the full description (terms 2.2).
- No mentions of iPhone, iOS, App Store, or competitor names (Google Photos, iCloud, etc.).
- No keyword stuffing, emojis spam, or promotional superlatives ("#1", "Best").

Templates to adapt:

- **App name (30 chars max):** `Lelvo: Photo Backup`
- **Short description (80 chars max):** `Back up your photos and videos to a private channel in your own account.`
  (No "Telegram" here: Play shows it beside the title and icon, where it reads as Telegram's own app.)
- **Full description (4000 chars max):**
  ```
  Lelvo uses the Telegram API and is part of the Telegram ecosystem. It is not made by,
  affiliated with or endorsed by Telegram. You need an existing Telegram account.

  Back up your photos and videos to a private channel in your own Telegram account, and
  browse your whole library in one fast timeline.

  • Original quality backups of photos and videos
  • One timeline for photos on this phone and in your backup
  • Stream backed-up videos without downloading them first
  • End-to-end encryption with your own passphrase and recovery key
  • Restore everything on a new phone by signing in
  • Automatic background backup that continues where it left off
  • Free up space on your phone after items are verified in your backup

  Your data stays yours: Lelvo has no servers, no accounts of its own, no analytics and no
  ads. Photos go directly from your phone to your own Telegram account, and we never
  receive them.

  Storage in your Telegram account is subject to Telegram's terms.
  ```

### 5.5 Store graphics & screenshots

- [ ] 📝 **App icon:** 512 × 512 PNG (32-bit, max 1 MB). Original icon, no Telegram logo or paper plane.
- [ ] 📝 **Feature graphic:** 1024 × 500 PNG or JPEG (required by Google Play). Clean branding, no Telegram logo.
- [ ] 📝 **Phone screenshots:** 4–8 images (16:9 or 9:16, min 320 px, max 3840 px; recommended 1080 × 2400).
      Must be **real Android app screens** using the demo library (Unsplash photos). No iPhone device frames, no iOS
      status bar, no real people's faces without permission, no Telegram logo.
- [ ] 📝 **Suggested set:** Timeline · Photo viewer · Backup progress · End-to-end encryption setup · Collections / Places · Restore.

---

## Phase 6 — If Google Play rejects the app

A rejection is normal and fixable. Read the exact policy email and Play Console → *Policy status*.

| Rejection | What it means | Fix / appeal |
|---|---|---|
| **Photo and Video Permissions** | Reviewer wants you to use the Android Photo Picker | Resubmit the declaration emphasizing that Lelvo is a continuous cloud backup & unified gallery app (core functionality cannot work with one-time Photo Picker selection). Include a short video showing the unified local+cloud timeline and automatic backup. |
| **Foreground Service (`dataSync`)** | Reviewer didn't see the notification or justification | Upload a clearer 20-second screen recording showing the user tapping Back up now and the ongoing notification in the shade. |
| **Location Permission / Data Safety mismatch** | `ACCESS_FINE_LOCATION` or `ACCESS_COARSE_LOCATION` found in merged manifest | Confirm `tools:node="remove"` stripped both from `AndroidManifest.xml` (Phase 3.1) and upload a new `.aab`. |
| **App Access / Broken Functionality** | Reviewer couldn't sign in | Confirm `+1 555 010 0199` and `24680` work on the exact `.aab` versionCode under review, and verify instructions in *App content → App access*. |
| **Impersonation / Intellectual Property** | Name, icon, or listing looks like Telegram | Verify "Telegram" is not in the title, icon, or feature graphic, and keep the non-affiliation disclosure at the top of the description. Link https://core.telegram.org/api/terms in any appeal. |
| **Data Safety discrepancy** | Play scanner detected network traffic not listed in Data Safety | Re-check Phase 5.3 (Phone number, User ID, Photos, Videos, Approximate location) and confirm `CctBackendFactory` is stripped. |
| **16 KB page size failure** | A native `.so` is 4 KB aligned | Re-run the `llvm-objdump` check from Phase 3.4 on the release `.aab` and update the offending native library or NDK flags. |

---

## Quick status

| Item | Status |
|---|---|
| `targetSdk = 36`, `minSdk = 29` | ✅ done |
| 16 KB page size alignment (all 6 `.so` libs) | ✅ verified |
| Demo Mode on Android (`+1 555 010 0199` / `24680`) | ✅ done |
| Telegram disclosure in Intro & About | ✅ done |
| `ProStore.OFFERED = false` (no external payments) | ✅ done |
| Debug screens gated behind `BuildConfig.DEBUG` | ✅ done |
| Privacy policy live (`https://lelvo.app/privacy`) | ✅ done |
| Strip merged `ACCESS_COARSE_LOCATION` & `ACCESS_FINE_LOCATION` | ✅ done (`AndroidManifest.xml`) |
| Add MapLibre & ML Kit to `ACKNOWLEDGEMENTS` & `NOTICE.md` | ✅ done (`HelpScreens.kt`, `NOTICE.md`) |
| Add `.aab` (`bundleRelease`) & `mapping.txt` to Android release workflow | ✅ done (`android-release.yml`) |
| Align ML Kit wording in `PRIVACY.md` | ✅ done (`PRIVACY.md`) |
| `play-store-review` compliance skill installed & run | ✅ done (`.agents/skills/play-store-review`) |
| Privacy page has no path to the donation page (`BARE` in `Scripts/website-pages.py`) | ✅ done |
| **Release (R8) build tested on the Pixel_9 emulator, clean install** (28 Nov): intro, Photos denied, demo sign-in, timeline, video playback, map tiles, search, simulated backup, About links, Sign out and reset. No crash, no R8 errors | ✅ done |
| Intro promised search by "text and things" (Pro-only / not on Android): now "Places, dates and kinds of photos" (Android and iOS) | ✅ done |
| Demo Backup tab showed 0 everywhere: now 6 on this phone · 36 only in the cloud, 6 verified after Back up now (Android; iOS counts aligned) | ✅ done |
| Intro feature pictures on Android are iPhone screenshots (iOS status bar and tab bar) | ⬜ polish, not a rejection cause: replace with Android demo screens |
| Real Telegram sign-in on the release build (production servers) | 🧪 todo with a spare account, not the owner's |
| Play Console account, declarations, Data Safety, screenshots | 📝 todo |
| Closed testing (12 testers × 14 days, if Personal account) | 🧪 todo |
