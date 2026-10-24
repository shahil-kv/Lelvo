# Releasing

The iOS and Mac apps release independently, each with its own version and tag. Pushing a tag builds the app on
GitHub Actions and publishes a GitHub Release with the file attached.

| App | Version setting in `project.yml` | Tag | Release file |
|---|---|---|---|
| iPhone / iPad | `settings.base.MARKETING_VERSION` | `ios-v2.1.0` | `CloudGallery.ipa` (unsigned, for sideloading) |
| Mac | `targets.CloudGalleryMac.settings.base.MARKETING_VERSION` | `macos-v1.1.0` | `CloudGallery-mac.zip` (Apple silicon + Intel) |

A tag with a suffix (`ios-v2.1.0-beta.1`) is published as a pre-release. The workflow refuses a tag that doesn't match
the app's `MARKETING_VERSION`.

## Steps

1. **Check `main` is green** in CI.
2. **Test on real devices** with a real Telegram account (a spare one), on the oldest and newest supported OS:
   - fresh install → sign in → create a library → back up photos, a Live Photo and a video;
   - view and stream from the cloud, share, save to Photos;
   - kill the app mid-backup and relaunch: it resumes without duplicates;
   - reinstall → sign in → the library restores and links to the photos on the device;
   - an end-to-end encrypted library: create, back up, unlock on a second device;
   - Free Up Space on a couple of items;
   - Mac: the same flow, plus hourly automatic backup with the window closed.
3. **Bump the version** in `project.yml`: `MARKETING_VERSION` for the app you release, and increase
   `CURRENT_PROJECT_VERSION` (build number) every time.
4. **Update [CHANGELOG.md](CHANGELOG.md)**: move "Unreleased" items under the new version and date, written for users.
5. Commit (`Release iOS 2.1.0`), push, then tag and push the tag:
   ```sh
   git tag ios-v2.1.0 && git push origin ios-v2.1.0
   ```
6. **Check the release page**: the file and its `.sha256` are attached, the notes read well. Edit the notes to
   summarise the changelog entry.

## App keys in releases

Release builds include the project's Telegram app keys from the repository secrets `TD_API_ID` and `TD_API_HASH`, so
users start sign-in at the phone number. The keys belong to a separate Telegram account kept only for this purpose
(see [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md#phase-0--accounts-and-keys-do-first)). Without the secrets, builds
ask users for their own keys.

```sh
gh secret set TD_API_ID --body "<id>"
gh secret set TD_API_HASH --body "<hash>"
```

## Later: signed builds

- **App Store and TestFlight (iOS):** follow [APP_STORE_RELEASE.md](APP_STORE_RELEASE.md). Archive with a
  distribution certificate in Xcode, or add signing secrets and an `xcodebuild -exportArchive` step to
  `release-ios.yml`.
- **Mac outside the App Store:** with a paid Apple Developer account, sign with a Developer ID certificate, notarize
  with `xcrun notarytool submit --wait`, staple with `xcrun stapler staple`, and ship a DMG. Users then open the app
  without the right-click step. A Homebrew cask can follow once releases are notarized.
- **Mac App Store:** needs the App Sandbox (`com.apple.security.app-sandbox`) and a review of file locations in
  `AppPaths`; plan it as its own project.
