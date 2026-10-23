# CloudGallery for iOS

A native SwiftUI app that backs up your iPhone's photos and videos, **bit for bit**, into a private channel in **your own Telegram account**. It works like Google Photos or iCloud Photos, with your Telegram as the storage. No servers, no accounts, no tracking.

Based on [AKS-Labs/CloudGallery](https://github.com/AKS-Labs/CloudGallery) (Android) and **Whitehole**. Licensed GPL-3.0. Storage format: [docs/CLOUD_FORMAT.md](../docs/CLOUD_FORMAT.md) (shared with the Android app).

## What it does

- **Originals, untouched**: HEIC, HEVC, ProRAW, ProRes, 4K/60, HDR and Dolby Vision are uploaded as documents with content-type detection off. EXIF, GPS and HDR metadata survive.
- **Any size**: TDLib signs in as your account, so files up to 2 GB (4 GB with Premium) upload directly, and larger ones are split into parts automatically.
- **Streaming video**: videos play from Telegram in a second or two, with instant seeking, Picture in Picture, AirPlay and playback speed. Nothing is fully downloaded first.
- **Live Photos**: the still and the paired video are both uploaded and play as a Live Photo.
- **Restore = sign in**: the channel is the source of truth. On a new phone, sign in and the whole library reappears; nothing to export or import.
- **No duplicates**: matched by Photos identifier and SHA-256, even across reinstalls and devices.
- **Reliable queue**: pending → uploading → verified, or failed with a reason and a Retry button. An item counts only once Telegram confirms every part with the right size. `FLOOD_WAIT` is respected, with at most 2 uploads at once.
- **Optional end-to-end encryption**, chosen when the library is created: AES-256-GCM in 1 MiB chunks (still streamable), captions encrypted too.
- **Gallery**: one timeline of phone and cloud items by day, month or year; pinch to resize; date scrubber; Albums (Videos, Live Photos, Favorites, cloud-only and your albums); drag-to-select; share, save, delete from cloud or iPhone.
- **Free up space** (off by default): deletes only items verified in the cloud.
- **Shortcuts**: Back Up New Photos, Backup Status, Free Up Space.

---

## 1. Install with SideStore, AltStore or Sideloadly (free Apple ID)

1. Download **CloudGallery.ipa** from the [latest release](https://github.com/shahil-kv/CloudGallery/releases/latest), or from the newest [iOS workflow run](https://github.com/shahil-kv/CloudGallery/actions/workflows/ios.yml) (artifact `CloudGallery-ipa-xcode-27`). It is unsigned; your sideloading tool signs it.
2. **SideStore** (no computer needed after setup): open SideStore → **My Apps** → **+** → pick `CloudGallery.ipa`. SideStore refreshes apps on-device every few days, as long as its pairing file and VPN/LocalDevVPN are set up.
3. **AltStore**: AltStore → My Apps → **+**. AltServer on your computer refreshes apps automatically over Wi-Fi.
4. **Sideloadly**: drag the IPA in, enter your Apple ID, Start.
5. First launch: **Settings → General → VPN & Device Management** → trust your Apple ID, and turn on **Settings → Privacy & Security → Developer Mode** if asked.

**7-day signing**: free Apple IDs sign apps for 7 days. SideStore and AltStore refresh automatically before that; with Sideloadly, install the same IPA again. Installing over the existing app keeps your sign-in and data. Even if it expires and you reinstall from scratch, sign in again and the library comes back from Telegram.

> Updating from 1.0 (Bot API)? Version 2 uses your own account and a new storage format. Install 2.x over 1.0, sign in, and create or pick a library. Your 1.0 uploads stay in the old channel in Telegram.

## 2. Get your Telegram API key (one time, 2 minutes)

Telegram requires every third-party client to have an `api_id`/`api_hash`. You create your own; it never leaves your phone.

1. Open **[my.telegram.org](https://my.telegram.org)** and log in with your phone number (Telegram sends the code to your Telegram app).
2. Tap **API development tools**.
3. Fill in App title `CloudGallery`, Short name `cloudgallery`, Platform `iOS`. The URL and description are optional. Tap **Create application**.
4. Copy **App api_id** (a number) and **App api_hash** (32 characters).

## 3. First launch

1. **Get started** → paste `api_id` and `api_hash`.
2. Enter your **phone number** → enter the **login code** Telegram sends you (in the Telegram app) → your **two-step password** if you have one.
3. **Your library**:
   - **New user**: tap **Create "CloudGallery Library"**. Turn on **End-to-end encryption** first if you want it (you can't change it later). With E2E, choose a strong passphrase and store it in a password manager: **a lost passphrase means lost photos**.
   - **New phone or reinstall**: pick your existing **CloudGallery Library** from the list. The app reads the channel and the gallery reappears; for E2E libraries, enter the passphrase.
4. Allow **Full Access** to Photos.
5. Open **Backup → Back up now**. For a big first backup, keep the app open on Wi-Fi and power. On iOS 26+ it keeps going in the background, with progress on the Lock Screen.

Your `api_id`/`api_hash`, the TDLib session key and the E2E key are stored only in this iPhone's Keychain. The TDLib session database is encrypted.

## 4. Shortcuts automations

**Back Up New Photos** runs without opening the app: it uploads for about 25 seconds (the time iOS allows Shortcuts in the background) and reports what it did. The queue is saved, so the next run continues where this one stopped.

**When charger is connected**: Shortcuts → Automation → **+** → **Charger** → **Is Connected** → **Run Immediately** → add **CloudGallery → Back Up New Photos** → Done.

**Daily at 2 AM**: Shortcuts → Automation → **+** → **Time of Day** → 2:00 AM, Daily → **Run Immediately** → add **Back Up New Photos** → Done.

CloudGallery also schedules an overnight backup task that iOS runs while the phone is charging.

## 5. Restoring on a new phone

Install, sign in with the same Telegram account, and pick your **CloudGallery Library**. The app scans the channel's history and rebuilds everything: dates, locations, albums, favourites and Live Photo pairs. Photos still on the phone are matched by content hash, so they aren't uploaded again.

## 6. Limits and honest notes

- **Background uploads on iOS**: Telegram's protocol (MTProto) can't use iOS background transfers. Uploads run while the app is open, during **Back up now** (continued in the background on iOS 26+), during the overnight charging task, and for ~25 s per Shortcut run.
- **Telegram limits**: per-file 2 GB (4 GB Premium), with larger files split automatically. Telegram may ask us to slow down (`FLOOD_WAIT`); the app waits as instructed.
- **Smooth streaming copies** (1080p previews for huge videos) are not implemented yet; originals stream directly.
- **Your account, your responsibility**: one account, normal use, no tricks. Telegram's terms can change, so keep important memories in more than one place.

## FAQ

**Why does it need my phone number?** It signs in to *your* Telegram account (like any Telegram app) so files go to your own channel with large-file support. The session is stored encrypted on this iPhone only.

**Can I open my photos in Telegram?** Yes, for plain libraries: they're normal files in your channel. Encrypted libraries show `.cge` files that only CloudGallery can open.

**Does it work with the Android app?** Yes. Both apps use the same format ([docs/CLOUD_FORMAT.md](../docs/CLOUD_FORMAT.md)), so one library works on both.

**Where did my storage go?** Settings → Storage shows the thumbnail, photo and video caches; all are capped and can be cleared. Viewing cloud items never permanently uses phone storage.

**I deleted photos with Free Up Space but storage didn't change.** Empty **Photos → Albums → Recently Deleted**.

**Logs for a bug report?** Settings → Logs → Share. Phone numbers, keys and passphrases are redacted.

## Building from source

Requires macOS with Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd ios && brew install xcodegen && xcodegen generate && open CloudGallery.xcodeproj
cd ios/CloudGalleryCore && swift test   # format, crypto, queue, cache tests
```

CI (`.github/workflows/ios.yml`) builds with the newest Xcode on `macos-latest` and on GitHub's `xcode-27` preview runner (iOS 27 SDK), runs the tests on a simulator, and packages an unsigned `CloudGallery.ipa`. Tags `v*` publish a release.
