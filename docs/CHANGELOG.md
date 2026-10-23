# Changelog

## 2.0.0-beta.1 (iOS), 2026-10-23
- **Telegram user account via TDLib** replaces the Bot API: no 50 MB / 20 MB limits; files over 2 GB (4 GB Premium) are split automatically.
- **Cloud format 1** (docs/CLOUD_FORMAT.md): one document per resource with versioned caption JSON; restore by scanning channel history (no index file).
- Persistent upload queue with verification, FLOOD_WAIT handling, 2 concurrent uploads, failed-items screen with Retry.
- Streaming video playback with instant seeking, PiP, AirPlay and playback speed; prefetching of adjacent videos.
- Optional end-to-end encryption chosen at library creation (PBKDF2 600k, chunked AES-GCM, encrypted captions).
- Albums tab, year/month/day timeline, date scrubber, drag-to-select, delete from iPhone, codec/HDR info.
- Selection filters: photos/videos only, date range, charging only; capped caches with TDLib storage optimizer.
- UI smoke tests; cross-platform test vectors.
- Docs: issues analysis, architecture, cloud format.

## 1.0.0 (iOS), 2026-10-23
- First native iOS app (SwiftUI) using the Telegram Bot API: original-quality backup, Live Photos, SHA-256 de-duplication, background `URLSession` uploads, an encrypted pinned index for restore, optional E2E encryption, gallery and viewer, Free Up Space (off by default), and Shortcuts actions.
- CI builds an unsigned IPA with Xcode 26.6 and Xcode 27.1.
