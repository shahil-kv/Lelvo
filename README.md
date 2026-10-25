# Memvo

**Back up every photo and video, in original quality, to a private channel in your own Telegram account.
Browse it all in one fast timeline on iPhone and Mac.**

<p align="center">
  <a href="https://github.com/shahil-kv/Memvo/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/shahil-kv/Memvo?include_prereleases&sort=semver&label=release&color=1F6FEB"></a>
  <a href="https://github.com/shahil-kv/Memvo/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/shahil-kv/Memvo/ci.yml?branch=main&label=CI"></a>
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20UIKit%2FAppKit-F05138?logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-3DA639"></a>
</p>

**Website: [memvo.mshahilkv.workers.dev](https://memvo.mshahilkv.workers.dev)**

Free, open source, and staying that way. No servers, no accounts of our own, no analytics, no ads.
Your photos go straight from your device to your Telegram account, and nowhere else.

> [!NOTE]
> Memvo uses the Telegram API. It is an independent app, not made, endorsed or supported by Telegram.
> Your storage lives in your Telegram account and is subject to [Telegram's Terms of Service](https://telegram.org/tos).

## Contents

- [What it does](#what-it-does)
- [Install](#install)
- [First launch](#first-launch)
- [Before you trust it with your only copy](#before-you-trust-it-with-your-only-copy)
- [Questions people ask](#questions-people-ask)
- [Privacy](#privacy)
- [Contributing](#contributing)
- [Building from source](#building-from-source)
- [License and credits](#license-and-credits)

## What it does

- **Originals, untouched.** HEIC, ProRAW, HEVC, ProRes, 4K/60, HDR and Dolby Vision are uploaded bit for bit, with
  EXIF and location intact. Edited photos keep both the original and the edit.
- **Big files work.** Files up to 2 GB (4 GB with Telegram Premium) upload directly; anything larger is split into
  parts and joined again on download.
- **One timeline.** Photos on this device and everything in your backup, by day, month or year, with pinch to resize,
  a date scrubber, albums, favourites, videos and Live Photos.
- **Stream, don't download.** Backed-up videos play in a second or two straight from Telegram, with seeking,
  Picture in Picture and AirPlay.
- **Restore by signing in.** Your channel is the source of truth. On a new phone or after a reinstall, sign in and the
  library comes back: dates, places, albums and Live Photo pairs.
- **Never twice.** Items are matched by Photos identifier and SHA-256, so nothing is uploaded twice, even across
  reinstalls and devices. A Duplicates screen cleans up what's already doubled.
- **Nothing counts until it's verified.** An item is "backed up" only after Telegram confirms every part with the
  right size. Failures keep their reason and a Retry button.
- **Optional end-to-end encryption**, chosen when you create a library: AES-256-GCM in 1 MiB chunks (still
  streamable), captions encrypted too, key derived from your passphrase on your device.
- **Free up space** safely: only items verified in Telegram and unchanged since their backup are offered.
- **Download a copy** of the whole library to Files, an external drive or a Mac folder at any time. You're never
  locked in.
- **Mac app** with a Photos-style sidebar, menu bar status, keyboard shortcuts, drag to Finder and hourly backups.
- **Shortcuts** on iPhone: Back Up New Photos, Backup Status, Free Up Space.

## Install

| | How | Notes |
|---|---|---|
| **iPhone / iPad** | Download `Memvo.ipa` from [Releases](https://github.com/shahil-kv/Memvo/releases/latest) and install it with [SideStore](https://sidestore.io), [AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io) | iOS 17 or later. The App Store version is in preparation. |
| **Mac** | Download `Memvo-mac.zip` from [Releases](https://github.com/shahil-kv/Memvo/releases/latest), unzip, move to Applications | macOS 15 or later, Apple silicon or Intel. |

<details>
<summary><b>Sideloading on iPhone, step by step</b></summary>

1. Download `Memvo.ipa` from the latest release. It's unsigned; your sideloading tool signs it with your
   Apple ID.
2. **SideStore**: My Apps → **+** → pick the IPA. SideStore refreshes it on the device every few days.
   **AltStore**: My Apps → **+**; AltServer on your computer refreshes it over Wi-Fi.
   **Sideloadly**: drag the IPA in, enter your Apple ID, Start.
3. First launch: **Settings → General → VPN & Device Management** → trust your Apple ID, and turn on
   **Settings → Privacy & Security → Developer Mode** if iOS asks.

Apps signed with a free Apple ID stop opening after **7 days** unless they're refreshed. SideStore and AltStore do
that for you. If it does expire, install the IPA again over the old one: your sign-in and data stay. Even after a
full reinstall, signing in brings the library back from Telegram.
</details>

<details>
<summary><b>Opening the Mac app the first time</b></summary>

Until releases are notarized by Apple, macOS may say it "can't check the app for malicious software". Right-click
Memvo in Applications → **Open** → **Open**. You only do this once.
</details>

## First launch

1. **Continue with Telegram** and enter the phone number of your Telegram account.
2. Enter the login code Telegram sends to your other Telegram apps (or by SMS), and your two-step password if you
   use one.
3. **Your library.** New here? Create one (Standard, or End-to-end encrypted). Coming back? Memvo finds your
   existing library and restores it.
4. Allow **Full Access** to Photos, then tap **Backup → Back up now**. For a big first backup, keep the app open on
   Wi-Fi and power. On iOS 26 and later it keeps going in the background with progress on the Lock Screen.

Builds made from source without app keys ask for a free `api_id` / `api_hash` first: see
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#telegram-app-keys).

## Before you trust it with your only copy

Memvo is careful, but your backup lives in a Telegram account that Telegram controls. Read these once:

1. **Telegram deletes inactive accounts**, and your channel goes with them. The default is 18 months without
   opening any Telegram app. Memvo shows the current setting and can change it to the maximum, 2 years
   (Settings → Telegram). Open the Telegram app now and then.
2. **Deleting the channel deletes the backup.** Your library is an ordinary channel in your Telegram. Deleting it
   removes every file in it, and a deleted channel can't be restored. Don't rename it to something you might clean
   up later, and don't delete messages in it by hand.
3. **A frozen or banned account can't upload.** Accounts restricted after reports from other users can still read
   but can't post, so backups stop until it's resolved in the Telegram app. Normal personal use doesn't cause this.
4. **Lost passphrase, lost photos.** For an end-to-end encrypted library nobody, including us, can recover the
   passphrase. Keep it in a password manager.
5. **Keep a second copy of what you can't lose.** That's good advice for any single service, including this one.
   **Settings → Download a copy of your library** makes that easy.

The details, with links to Telegram's own pages, are in **[docs/FAQ.md](docs/FAQ.md)**.

## Questions people ask

<details><summary><b>Is this allowed by Telegram?</b></summary>

Yes. Telegram's API is open to third-party apps under the [Telegram API Terms of Service](https://core.telegram.org/api/terms).
Memvo uses its own `api_id`, says on its welcome screen that it uses the Telegram API, doesn't use
"Telegram" in its name or Telegram's logo, and doesn't change how Telegram works for anyone else.
</details>

<details><summary><b>Is Telegram storage really unlimited?</b></summary>

Telegram describes its cloud storage as unlimited, with files up to 2 GB each (4 GB with Premium); see
[Telegram's Terms of Service](https://telegram.org/tos) and the [Telegram FAQ](https://telegram.org/faq). That's Telegram's promise, not ours, and it can change. Memvo splits
bigger files automatically.
</details>

<details><summary><b>Can Telegram see my photos?</b></summary>

In a **Standard** library, files are protected in transit and on Telegram's servers like any other cloud chat, but
cloud chats are not end-to-end encrypted ([Telegram FAQ](https://telegram.org/faq#q-so-how-do-you-encrypt-data)).
In an **End-to-end encrypted** library, files and captions are encrypted on your device before upload; Telegram only
stores unreadable `.cge` files.
</details>

<details><summary><b>What if I delete the channel by mistake, or my account is deleted or frozen?</b></summary>

See [docs/FAQ.md → When something goes wrong in Telegram](docs/FAQ.md#when-something-goes-wrong-in-telegram). Short
version: a deleted channel or account can't be brought back; a frozen account can still be read and can appeal in
the Telegram app; photos still on your phone are never deleted by any of this.
</details>

<details><summary><b>Will it fill up my phone?</b></summary>

No. Thumbnails and viewed items are cached with hard limits (300 MB and 1 GB by default) and can be cleared in
Settings → Storage. Viewing cloud items never keeps them permanently.
</details>

<details><summary><b>Android? Windows? Web?</b></summary>

Not planned for now; the project is focused on making the Apple apps excellent. See
[docs/not-planned.md](docs/not-planned.md).
</details>

More in **[docs/FAQ.md](docs/FAQ.md)**. Still stuck? See **[SUPPORT.md](SUPPORT.md)**.

## Privacy

Memvo has no servers and collects nothing: no analytics, no crash reporting, no tracking. Your phone number
and login code go only to Telegram. Your Telegram session, app keys and encryption key stay in this device's
Keychain. Logs stay on the device unless you choose to share them, and phone numbers, keys and IDs are removed from
them first. Full policy: **[PRIVACY.md](PRIVACY.md)**.

## Contributing

Bug reports, ideas, translations and code are all welcome. Please read **[CONTRIBUTING.md](CONTRIBUTING.md)** first:

- **Bugs and ideas** start as [issues](https://github.com/shahil-kv/Memvo/issues/new/choose), using the forms.
- **Code**: wait for the issue to be labelled `approved`, then open a pull request that says `Closes #<number>`.
  Pull requests without an approved issue are closed automatically. Docs-only changes don't need approval.
- Every pull request needs the one-time [Contributor License Agreement](CLA.md) (a bot asks you on your first PR).
- Be kind: [Code of Conduct](CODE_OF_CONDUCT.md). Security problems: [SECURITY.md](SECURITY.md), never a public issue.

## Building from source

Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
git clone https://github.com/shahil-kv/Memvo.git && cd Memvo
xcodegen generate && open Memvo.xcodeproj
```

```text
iOS/                     iPhone and iPad app
macOS/                   Mac app
Shared/                  services and screens both apps use (Telegram, backup engine, onboarding, settings)
Packages/MemvoCore  storage format, encryption, index, upload queue, with unit tests
UITests/                 iOS UI tests
Config/                  build settings; your Telegram app keys go in Config/Secrets.xcconfig (never committed)
docs/                    FAQ, architecture, storage format, development and release guides
```

Everything else (app keys, tests, the device workflow, releasing) is in
**[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**.

## License and credits

Memvo is free software under the **[GNU General Public License v3.0](LICENSE)**: you may use, study, share
and change it, and copies you distribute must stay under the same license with their source code. Contributions are
accepted under the [Contributor License Agreement](CLA.md). The Memvo name and icon are covered by
[TRADEMARKS.md](TRADEMARKS.md). Third-party licenses: [NOTICE.md](NOTICE.md).

Inspired by [AKS-Labs/CloudGallery](https://github.com/AKS-Labs/CloudGallery) and Whitehole, earlier projects that
back up photos to Telegram. This codebase is a separate, from-scratch implementation for Apple platforms.
