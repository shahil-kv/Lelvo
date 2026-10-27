# Changelog

User-facing changes for each release. iOS versions are tagged `ios-v*`, Mac versions `macos-v*`
([RELEASING.md](RELEASING.md)).

## Unreleased

- **New name: Memvo** (was CloudGallery), with new bundle IDs, so it installs as a new app: sign in once and your
  library comes back. Existing libraries in Telegram keep working unchanged.
- **Own repository.** Memvo is now a standalone, community-driven project under the GPL-3.0, with a
  contributor agreement, issue forms, an `approved`-issue rule for pull requests, CI on every pull request and
  automated reviews. The iOS and Mac apps live side by side (`iOS/`, `macOS/`, `Shared/`).
- **Sign-in:** login codes of any length (Telegram sends 5 or 6 digits) and codes sent as a word or phrase.
- **Telegram account problems** are explained plainly: frozen accounts, and limits on creating channels.
- **About** shows the source code, license, privacy policy, help and the licenses of included libraries.
- **Privacy manifests** for both apps (no tracking, no data collected).
- Release builds no longer contain the test switches used by UI tests.
- **Sign-in starts at your phone number** in every build; a build without Telegram app keys asks for them after.
- **iPhone only** for now (it still runs on iPad in iPhone mode), and a **demo library** for App Review that never
  connects to Telegram.
- New website pages: [changelog](https://memvo.mshahilkv.workers.dev/changelog) and
  [privacy policy](https://memvo.mshahilkv.workers.dev/privacy).
- **Fast cloud videos:** each video you back up also gets a small fast version (about a tenth of the size), so it
  plays at once from your Telegram library. The quality button in the viewer switches to the original at any time,
  and older videos can get one with Make Fast Version. Cloud videos seek instantly, keep playing when you switch
  between Wi-Fi and mobile data, and the videos on screen and the photos next to the one you're viewing are fetched
  ahead so they open at once.
- **Saving a cloud video** shows its progress and can be cancelled.
- **Recently Deleted for your backup:** deleting from the cloud keeps the item for 30 days, so you can recover it.
- Versions restart at **0.1.0** for both apps in this repository, released with a one-button Release workflow. Compiler warnings fixed on both platforms.
- **Backups keep everything Photos keeps**, and **Save to Photos puts photos back as they were:** the original with
  its edit (Revert in Photos still works), the RAW of RAW + JPEG photos, Live Photos, favourites, hidden photos and
  the same albums. Photos backed up earlier get the missing pieces from your iPhone or Mac at the next backup.
- **Include hidden photos** in the backup (off by default). Memvo never shows them, and they come back hidden.
- **Share Original** (touch and hold Share on iPhone) and **Export Unmodified Original** on the Mac.
- **Big photos open at once from the cloud:** RAW photos and photos over 3 MB get a small screen copy when backed up,
  shown immediately while the original loads when you zoom in. Photos backed up earlier get one gradually, from files
  already on your iPhone or Mac. Sharing, saving and exporting always use the original.
- **Smoother timeline during a backup** in large libraries: only the photos that changed are updated, instead of
  the whole library being read again every second or two.

## Before this repository

Released from the earlier fork, under the name CloudGallery, as iOS 1.0.0 and 2.0.0 betas. If you installed one of those, delete it and install
0.1.0; your library comes back when you sign in.

### 2.0.0-beta.1 (iOS), 2026-10-23
- **Telegram user account via TDLib** replaces the Bot API: no 50 MB / 20 MB limits; files over 2 GB (4 GB Premium) are split automatically.
- **Cloud format 1** (docs/CLOUD_FORMAT.md): one document per resource with versioned caption JSON; restore by scanning channel history (no index file).
- Persistent upload queue with verification, FLOOD_WAIT handling, 2 concurrent uploads, failed-items screen with Retry.
- Streaming video playback with instant seeking, PiP, AirPlay and playback speed; prefetching of adjacent videos.
- Optional end-to-end encryption chosen at library creation (PBKDF2 600k, chunked AES-GCM, encrypted captions).
- Albums tab, year/month/day timeline, date scrubber, drag-to-select, delete from iPhone, codec/HDR info.
- Selection filters: photos/videos only, date range, charging only; capped caches with TDLib storage optimizer.
- UI smoke tests; cross-platform test vectors.
- Docs: issues analysis, architecture, cloud format.

### 1.0.0 (iOS), 2026-10-23
- First native iOS app (SwiftUI) using the Telegram Bot API: original-quality backup, Live Photos, SHA-256 de-duplication, background `URLSession` uploads, an encrypted pinned index for restore, optional E2E encryption, gallery and viewer, Free Up Space (off by default), and Shortcuts actions.
- CI builds an unsigned IPA with Xcode 26.6 and Xcode 27.1.
