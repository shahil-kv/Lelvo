# Releasing

Releases are one button. Versions follow [Semantic Versioning](https://semver.org): `0.MINOR.PATCH` until the App
Store launch makes it 1.0.0. MINOR for new features, PATCH for fixes only.

## Steps

1. **Check `main` is green** in CI, and that **[CHANGELOG.md](CHANGELOG.md)** "Unreleased" describes the changes for
   users. Move them under the new version and date in the same pull request.
2. **Test on real devices** with a real (spare) Telegram account, on the oldest and newest supported OS:
   - fresh install → sign in → create a library → back up photos, a Live Photo and a video;
   - view and stream from the cloud, share, save to Photos;
   - kill the app mid-backup and relaunch: it resumes without duplicates;
   - reinstall → sign in → the library restores and links to the photos on the device;
   - an end-to-end encrypted library: create, back up, unlock on a second device;
   - Free Up Space on a couple of items;
   - Mac: the same flow, plus hourly automatic backup with the window closed.
3. **GitHub → Actions → Release → Run workflow** on `main`, and choose:
   - **app**: `ios`, `macos` or `both`;
   - **channel**: `beta` (testers) or `stable`;
   - **version**: e.g. `0.2.0` (no suffix).
4. The workflow does the rest:

| | Beta | Stable |
|---|---|---|
| Version in the app | `0.2.0` | `0.2.0` |
| Build number | the workflow run number (always increases) | same |
| Tag | `ios-v0.2.0-beta.<run>`, `macos-v0.2.0-beta.<run>` | `ios-v0.2.0`, `macos-v0.2.0` |
| Release page | pre-release | latest release |
| Files | `Memvo.ipa` / `Memvo.dmg` and `Memvo-mac.zip`, each with `.sha256` | same |
| Notes | merged pull requests since the last release of that app, grouped by label (`.github/release.yml`) | same |

It refuses to run off `main`, refuses a malformed version, and refuses a tag that already exists. Ship as many betas
of `0.2.0` as you like, then run it once as `stable`.

5. **Check the release page** and edit the notes into a short summary for users if needed.

## App keys in releases

Release builds include the project's Telegram app keys from the repository secrets `TD_API_ID` and `TD_API_HASH`, so
users start sign-in at the phone number. The keys belong to a separate Telegram account kept only for this purpose
(see [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md#phase-0--accounts-and-keys-do-first)). Without the secrets, builds
ask users for their own keys.

```sh
gh secret set TD_API_ID --body "<id>"
gh secret set TD_API_HASH --body "<hash>"
```

## TestFlight

The iOS job also signs the build and uploads it to App Store Connect when these repository secrets exist (without
them the step is skipped and only the unsigned build is published):

| Secret | Where it comes from |
|---|---|
| `APPLE_TEAM_ID` | developer.apple.com → Membership details → Team ID |
| `ASC_KEY_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API → your key's Key ID |
| `ASC_ISSUER_ID` | The same page, "Issuer ID" above the key list |
| `ASC_KEY_P8` | The `AuthKey_<id>.p8` file downloaded when the key was made (one download only): `gh secret set ASC_KEY_P8 -R shahil-kv/Memvo < AuthKey_<id>.p8` |

Give the key the **App Manager** role (Admin works too); Xcode then signs with the team's cloud-managed distribution
certificate and creates the provisioning profile itself. The app record must exist in App Store Connect first
(APP_STORE_RELEASE.md, Phase 5). The build appears in TestFlight after Apple's processing, 10–30 minutes later.
The workflow is written but untested until the Apple account exists; the first run may need a fix.

## Later: signed builds

- **App Store (iOS):** follow [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md); a TestFlight build is submitted for review
  from App Store Connect.
- **Mac outside the App Store:** with a paid Apple Developer account, sign with a Developer ID certificate, notarize
  with `xcrun notarytool submit --wait`, staple with `xcrun stapler staple`, and ship a DMG. Users then open the app
  without the right-click step. A Homebrew cask can follow once releases are notarized.
- **Mac App Store:** needs the App Sandbox (`com.apple.security.app-sandbox`) and a review of file locations in
  `AppPaths`; plan it as its own project.
