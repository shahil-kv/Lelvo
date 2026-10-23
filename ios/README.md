# CloudGallery for iOS

A native SwiftUI app that backs up your iPhone's photos and videos, **as untouched originals**, to a private Telegram channel that only you control. No servers, no accounts, no analytics.

It is the iOS sibling of the Android app in this repository and builds on the ideas of [AKS-Labs/CloudGallery](https://github.com/AKS-Labs/CloudGallery) and **Whitehole**, the original Telegram photo-backup projects. Licensed under GPL-3.0.

**Version 1** uses the Telegram **Bot API**. Version 2 (see [ROADMAP-v2.md](ROADMAP-v2.md)) will log in as your own account to lift the file-size limits.

---

## Features

- **Original quality**: HEIC, HEVC, ProRAW and so on are uploaded as documents with `sendDocument`, never recompressed. Original filenames, creation dates and locations are kept, both inside the file and in the index.
- **Live Photos**: the still and the paired video are both uploaded and linked in the index.
- **No duplicates**: items are tracked by PhotoKit identifier *and* SHA-256 of the original bytes, so nothing uploads twice, even after reinstalling or on a new phone.
- **Background uploads**: background `URLSession` uploads keep going when the app is suspended. An overnight `BGProcessingTask` runs while the phone is charging, and on iOS 26+ **Back up now** runs as a `BGContinuedProcessingTask` with system progress UI.
- **Rate limiting**: about one message per second per channel (one per three seconds in groups). HTTP 429 `retry_after` is honoured, with exponential backoff and automatic resume.
- **Encrypted cloud index**: after each batch, the list of everything backed up is encrypted (AES-GCM, PBKDF2-SHA256 with 250,000 iterations and a random salt) and **pinned** in your channel. A fresh install restores the whole gallery from it.
- **Optional end-to-end encryption**: when turned on, originals and thumbnails are encrypted on the phone before upload.
- **Gallery**: one timeline of phone and cloud items, pinch to zoom the grid, badges, a full-screen viewer with zoom, Live Photo and video playback, an info panel and multi-select actions.
- **Free Up Space** (off by default): deletes only photos verified to be in the cloud.
- **Shortcuts**: Back Up New Photos, Backup Status and Free Up Space.

## Bot API limits (version 1)

| Size of a file | Upload | View in app | Free Up Space |
|---|---|---|---|
| ≤ 20 MB | ✅ | ✅ | ✅ after verification |
| 20 to 50 MB | ✅ | ❌ "Needs version 2" (open it in Telegram) | ❌ never offered |
| > 50 MB | ❌ **not backed up**, listed under "Needs version 2" | ❌ | ❌ |

The app never claims a file is backed up unless Telegram has confirmed the message and returned a `file_id`. Large items are listed under **Backup → Needs version 2**.

---

## 1. Set up Telegram

### Create the bot
1. In Telegram, open **[@BotFather](https://t.me/BotFather)** and send `/newbot`.
2. Pick a display name and a username ending in `bot`.
3. Copy the **token** (`123456789:AAH…`). Anyone with it controls the bot, so keep it secret.

### Create a private channel (recommended) or supergroup
1. **New Channel** → set it to **Private**.
2. Channel → **Administrators** → **Add Admin** → search your bot. Turn on:
   - **Post Messages**
   - **Edit Messages of Others** (in channels this also allows pinning, and it is used to check that backups still exist)
   - **Delete Messages**
   - in a supergroup, also **Pin Messages**
3. Post any message in the channel (e.g. "hi"). The app uses it to find the chat ID automatically.

### Chat ID
The app reads it through `getUpdates` (**Detect chats**). To enter it by hand: it is the channel's numeric ID starting with `-100`, e.g. `-1001234567890`. If detection finds nothing, make sure no webhook is set on the bot and post another message.

> Use the chat **only** for CloudGallery. Don't delete or unpin the pinned `cloudgallery-index.cgx` message.

## 2. Install the app (free Apple ID)

Download **CloudGallery.ipa** from the latest [Release](https://github.com/shahil-kv/CloudGallery/releases) (or from the `CloudGallery-ipa` artifact of the latest [iOS workflow run](https://github.com/shahil-kv/CloudGallery/actions/workflows/ios.yml)). The IPA is unsigned; your sideloading tool signs it with your Apple ID.

On the iPhone, first turn on **Settings → Privacy & Security → Developer Mode** (it appears after the first sideload attempt; the phone restarts).

### Option A: Sideloadly (Windows/macOS)
1. Install [Sideloadly](https://sideloadly.io) and connect the iPhone by cable (trust the computer).
2. Drag `CloudGallery.ipa` in, enter your Apple ID, click **Start**.
3. On the iPhone: **Settings → General → VPN & Device Management** → trust your Apple ID.

### Option B: AltStore
1. Install [AltServer](https://altstore.io) on your computer and AltStore on the iPhone.
2. In AltStore → **My Apps** → **+** → choose `CloudGallery.ipa`.
3. AltStore **refreshes apps automatically** in the background whenever the iPhone and computer running AltServer are on the same Wi-Fi.

### The 7-day limit
Apps signed with a **free** Apple ID expire after **7 days**. Re-sign before then: AltStore does it automatically, and in Sideloadly you install the same IPA again. Your data (Keychain token, database) is kept when you re-sign the same app over itself. If the app does expire and you have to delete it, just restore from the cloud (section 5). A paid Apple Developer account gives 1-year signatures.

> Bundle ID: `com.shahil-kv.cloudgallery`. Some tools change it when signing with a free account; that is fine.

## 3. First-time setup in the app

1. **Welcome → Create a bot → Create a channel**: the instructions above.
2. **Bot token**: paste it; the app verifies it with `getMe`.
3. **Backup chat**: tap **Detect chats** and pick your channel, or type the ID.
4. **Test connection**: checks the bot is an admin that can post, delete and pin.
5. **Passphrase**: at least 10 characters. It encrypts the cloud index (and your files, if you turn on E2E encryption). **If you forget it, nobody can recover your index or encrypted files.** Keep it in a password manager. If the app finds an existing index in the chat, this step becomes **Restore**.
6. **Photos access**: choose **Allow Full Access**. With limited access only the photos you select are backed up (you can change the selection from the banner in Photos).
7. Open **Backup → Back up now**.

The token, chat ID and passphrase are stored **only in the iOS Keychain** (this device only, never in iCloud).

## 4. Shortcuts automations

The **Back Up New Photos** action runs **without opening the app**: it prepares new items for about 20 seconds, hands them to background uploads and returns a summary like "Queued 23 items". Anything left over is picked up by the next run.

**When charger is connected**
1. Shortcuts → **Automation** → **+** → **Charger** → **Is Connected**.
2. Choose **Run Immediately**.
3. Add the action **CloudGallery → Back Up New Photos** → **Done**.

**Daily at 2 AM**
1. Shortcuts → **Automation** → **+** → **Time of Day** → 2:00 AM, **Daily**.
2. Choose **Run Immediately**.
3. Add **CloudGallery → Back Up New Photos** → **Done**.

Other actions: **Backup Status** returns counts, and **Free Up Space** opens the app on that screen (iOS requires you to confirm deletions, so it can't run silently). The same guide is in the app under **Settings → Shortcuts automations**.

## 5. How restore works

- After every batch, the app builds an index of everything confirmed in the cloud (message IDs, `file_id`s, hashes, dates, locations, Live Photo pairs, the E2E key salt), compresses it, encrypts it with your passphrase and **pins** it in the chat as `cloudgallery-index.cgx`, replacing the previous one.
- On a fresh install, enter the same token, chat and passphrase. The app reads the pinned message with `getChat`, downloads and decrypts the index, and the whole gallery reappears. Thumbnails download on demand as you scroll.
- If the encrypted index ever grows past 19 MB, it is split into chunks and a small encrypted **manifest** listing them is pinned instead.
- On a new phone, items that are still on the phone are matched by content hash, so they are not uploaded again.
- **Settings → Export encrypted index to Files** saves a copy you can keep elsewhere, and **Restore from exported file** reads it back.

## 6. Privacy and security

- No analytics, tracking or third-party SDKs. The app only talks to `api.telegram.org`.
- Index encryption: AES-256-GCM, key from PBKDF2-HMAC-SHA256 (250k iterations, random 16-byte salt in the file header, header authenticated).
- E2E file encryption (optional): 1 MB chunks of AES-256-GCM with a per-file key derived by HKDF from your passphrase-derived master key. Chunk index and a final-chunk flag are authenticated, so truncation and reordering are detected.
- Without E2E encryption, Telegram can see your photos, as with any cloud backup. Captions contain an item ID and hash (no filenames when E2E is on).
- **Settings → Logs** shows a local log with the bot token, chat ID and passphrase redacted; you can share it for debugging.

## FAQ

**Is Telegram storage really unlimited?** Telegram does not currently cap total storage for channels. Their terms can change; keep important photos in more than one place.

**Why "Needs version 2" for big videos?** Bots can upload at most 50 MB and download at most 20 MB per file. Version 2 will use your own account (MTProto via TDLib) for files up to 2 GB (4 GB with Premium).

**Can I use the same bot/channel on two phones?** Yes, with the same passphrase. Each upload of the index replaces the pinned one, so back up from one phone at a time and restore on the other to refresh.

**Can I change the passphrase?** Not in version 1. Choose it carefully.

**Uploads seem stuck.** Check **Wi-Fi only** in Settings, Low Power Mode, and Background App Refresh. iOS decides when background uploads run; opening the app or **Back up now** speeds things up.

**The app expired after 7 days.** Re-sign it (section 2). Your data is kept if you install over the existing app.

**I deleted photos with Free Up Space but storage didn't change.** Empty **Photos → Albums → Recently Deleted**.

## Building from source

Requirements: macOS with Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd ios
brew install xcodegen
xcodegen generate
open CloudGallery.xcodeproj
```

The core logic (Bot API client, crypto, index, cache, de-duplication, rate limiting) lives in the `CloudGalleryCore` Swift package and has its own tests:

```sh
cd ios/CloudGalleryCore && swift test
```

CI (`.github/workflows/ios.yml`) generates the project, runs the tests on a simulator, archives with signing disabled, and packages `Payload/CloudGallery.app` into an unsigned `CloudGallery.ipa`. Tags `v*` publish a GitHub Release.
