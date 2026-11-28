# Install

How to get Lelvo on your Mac, Android phone or iPhone, set it up, and what to know before you rely on it. For what
it does, see [FEATURES.md](FEATURES.md).

- [Download](#download)
- [Getting started](#getting-started)
- [Before you trust it with your only copy](#before-you-trust-it-with-your-only-copy)
- [Building from source](#building-from-source)

## Download

| Platform | Get it | Requirements |
|---|---|---|
| **Mac** | [Download Lelvo.dmg](https://github.com/shahil-kv/Lelvo/releases/latest/download/Lelvo.dmg), open it and drag Lelvo to Applications | macOS 15 or later, Apple silicon or Intel. Signed and notarized by Apple. |
| **Android** | Download the `.apk` from the [latest release](https://github.com/shahil-kv/Lelvo/releases/latest) and open it on your phone | Android 10 or later (arm64) |
| **iPhone** <sup>beta</sup> | [Join the TestFlight beta](https://testflight.apple.com/join/N9uhRuEy), or [sideload the IPA](#sideloading-on-iphone) | iOS 17 or later. App Store release in preparation. |

One library works on all three: a photo backed up on one device shows on the others.

### Installing the APK on Android

1. Download `Lelvo-<version>.apk` from the [latest release](https://github.com/shahil-kv/Lelvo/releases/latest) on
   your phone.
2. Open the file. If Android asks, allow your browser or Files app to install unknown apps.
3. Tap **Install**. Later updates install over the existing app and keep your sign-in.

### Sideloading on iPhone

1. Download `Lelvo.ipa` from the [latest release](https://github.com/shahil-kv/Lelvo/releases/latest). It's unsigned;
   your sideloading tool signs it with your Apple ID.
2. **[SideStore](https://sidestore.io)**: My Apps → **+** → pick the IPA. It refreshes on the device every few days.
   **[AltStore](https://altstore.io)**: My Apps → **+**. AltServer on your computer refreshes it over Wi-Fi.
   **[Sideloadly](https://sideloadly.io)**: drag the IPA in, enter your Apple ID, then Start.
3. On first launch: **Settings → General → VPN & Device Management** → trust your Apple ID. Turn on
   **Settings → Privacy & Security → Developer Mode** if iOS asks.

Apps signed with a free Apple ID stop opening after 7 days unless refreshed. If that happens, install the IPA again
over the old one: your sign-in and data stay.

### Opening a Mac app you built yourself

Release builds are notarized and open like any other app. Builds from source are not, so macOS says it "can't check
the app for malicious software". Click **Done**, open **System Settings → Privacy & Security**, click **Open Anyway**
next to Lelvo, then **Open**. You only do this once.

## Getting started

1. Tap **Continue with Telegram** and enter your Telegram phone number.
2. Enter the code Telegram sends to your other Telegram apps, and your two-step password if you use one.
3. **New here?** Create a library, choose a passphrase and keep the recovery key somewhere safe.
   **Coming back?** Lelvo finds your library and restores it.
4. Allow **Full Access** to Photos, then tap **Backup → Back up now**. For a big first backup, keep the app open on
   Wi-Fi and power.

## Before you trust it with your only copy

Your backup lives in a Telegram account that Telegram controls. Read these once:

1. **Telegram deletes inactive accounts**, and the channel goes with them. Lelvo shows the setting and can raise it to
   2 years in **Settings → Telegram**. Open the Telegram app now and then.
2. **Deleting the channel deletes the backup**, and it can't be restored. Don't delete or edit its messages by hand.
3. **Losing both your passphrase and recovery key means losing the photos.** Nobody can recover them, including us.
4. **Keep a second copy of what you can't replace.** **Settings → Download a copy of your library** makes that easy.

Details, with links to Telegram's own pages, are in the [FAQ](FAQ.md#when-something-goes-wrong-in-telegram).

## Building from source

**iPhone and Mac:** Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/shahil-kv/Lelvo.git && cd Lelvo
xcodegen generate && open Lelvo.xcodeproj
```

**Android:** Android Studio and JDK 17. Put `sdk.dir` (and optionally `telegram.apiId` and `telegram.apiHash`) in
`android/local.properties`, then:

```sh
cd android && ./gradlew :core:test :app:assembleDebug
```

Builds without app keys ask for a free Telegram `api_id` and `api_hash` on first launch. App keys, tests, the device
workflow and releasing are covered in **[DEVELOPMENT.md](DEVELOPMENT.md)**.

```text
iOS/                 iPhone and iPad app
macOS/               Mac app
Shared/              Telegram, backup and screens shared by iPhone and Mac
Packages/LelvoCore/  storage format, encryption, index and upload queue, with unit tests
android/             Android app (Kotlin, Jetpack Compose)
docs/                FAQ, architecture, storage format, changelog, development and release guides
```
