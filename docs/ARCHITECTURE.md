# Architecture

Two native apps, iOS and macOS, share one codebase for everything below the screens and one storage contract
([CLOUD_FORMAT.md](CLOUD_FORMAT.md)). Each signs in to the user's **own Telegram account through TDLib** and stores
everything in one private channel.

```
                ┌──────────────── Telegram (user account, MTProto) ────────────────┐
                │  Private channel "CloudGallery Library"                           │
                │  one document message per resource/part, caption = CG1 JSON        │
                └──────────────────────────────▲───────────────────────────────────┘
                                               │ TDLib (TDLibKit / TDLibFramework)
 ┌─────────────────────────────────────────────┴──────────────────────────────────────────┐
 │ Shared/Services/Telegram                                                                 │
 │   TDService         one TDLib client: sign-in, sends confirmed by Telegram, ranged reads │
 │   LibraryService    create/pick channel, header, E2E keys, restore = scan history         │
 │   CloudUploader     encrypt (optional), split, one confirmed message per part, size check │
 │   MediaReader       byte ranges over parts + CGFE decryption (viewer, streaming, export)  │
 │   StreamingAsset    AVAssetResourceLoader on cgstream:// URLs → MediaReader               │
 │ Shared/Services                                                                           │
 │   BackupEngine      job queue: pending → uploading → verified | failed(reason), 2 lanes    │
 │   PhotoLibraryService  PhotoKit: candidates, original export, edits, save back            │
 │   FreeUpSpaceService   verify in Telegram, then delete through PhotoKit                   │
 │   BackgroundTasks   iOS: BGProcessing, BGAppRefresh, BGContinuedProcessing · Mac: hourly   │
 │ Packages/CloudGalleryCore (no UIKit/AppKit, unit-tested)                                  │
 │   caption codec · CGFE encryption · part layout · LibraryIndexer · LibraryStore (SQLite)  │
 │   JobMachine · Deduplicator · RestoreLinker · LRUDiskCache · Redactor                      │
 └─────────────────────────────────────────────▲──────────────────────────────────────────┘
                                               │
 ┌──────────────────────────────┬──────────────┴───────────────────────────────────────────┐
 │ iOS/                         │ macOS/                                                     │
 │ SwiftUI + UICollectionView   │ SwiftUI + NSCollectionView                                 │
 │ grid, viewer, App Intents    │ sidebar window, viewer, inspector, menu bar extra           │
 ├──────────────────────────────┴───────────────────────────────────────────────────────────┤
 │ Shared/Views: sign-in, settings, backup dashboard, free up space, duplicates, gallery model│
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

`AppEnvironment` (in `Shared/App`) creates the services once per process; the UI, background tasks and App Intents
all use the same instance. `AppModel` holds UI-wide state (onboarding, tabs, sign-in sheet).

## Principles

1. **The channel is the truth.** The local SQLite index is a cache rebuilt by scanning history. Counts come from
   verified items.
2. **Bit-for-bit originals** are sent as documents with content-type detection disabled.
3. **Nothing is "backed up" until verified**: Telegram has confirmed the message and the document size equals the
   uploaded stream size, for every part.
4. **Resumable and durable**: job states and finished parts live in the index; a killed app resumes where it stopped.
5. **Honest limits**: `FLOOD_WAIT` is honoured exactly, at most 2 uploads run at once, 1.5 s apart, one account.
6. **Small caches**: LRU caps plus TDLib `optimizeStorage`. Viewing never permanently uses storage.
7. **No secrets in code or logs**: app keys come from an ignored xcconfig or the user, session and keys live in the
   Keychain (this device only), and every log line is redacted.

## Job queue state machine

```
          enqueue                  start                  sent + size ok
 (none) ─────────▶ pending ─────────────▶ uploading ─────────────────────▶ verified
                     ▲  ▲                    │  │
          retry/     │  └──── FLOOD_WAIT ────┘  │ error
          resume     │       (wait, same state) ▼
                     └────────────────────── failed(reason, attempts)
```

- `uploading → pending` on app kill. Before re-uploading, a run first scans recent channel history so an upload that
  finished while the app was gone isn't sent twice.
- Transient errors retry with exponential backoff, up to 5 attempts; then the item waits for a manual **Retry**.
- `verified` items with a local asset are eligible for Free Up Space, after a fresh check in Telegram.

## Streaming

`MediaReader.read(item, role, range)`:
1. Map the plaintext range to the stream range (identity for plain files; chunk-aligned ciphertext range for CGFE).
2. Map the stream range to parts (`PartLayout.segments`).
3. For each part, read through TDLib: the player keeps one continuous `downloadFile` window ahead of the playhead
   (`TDService.streamRead`); other reads fetch exactly their range (`TDService.read`), serialised per file because
   TDLib keeps one download per file.
4. Decrypt the needed chunks and slice them to the requested range.

`StreamingAsset` answers AVPlayer's content-information and data requests on a unique `cgstream://` URL per player.
Seeking works even when a MOV's `moov` atom sits at the end of the file, because the player requests that range first.

## Platform specifics

| | iOS | macOS |
|---|---|---|
| Grid | `NativePhotoGrid` (UICollectionView, pinch between column counts, swipe to select) | `MacPhotoGrid` (NSCollectionView, zoom slider, keyboard, drag to Finder) |
| Viewer | `ViewerView`: paging, zoom, Live Photos, custom video controls, PiP, AirPlay | `MacViewer`: hero zoom from the tile, arrow keys, trackpad swipe, AVPlayerView |
| Background | `BGContinuedProcessingTask` (iOS 26+, user-started), `BGProcessingTask` (charging, overnight), App Intents | `NSBackgroundActivityScheduler` hourly while the app runs; App Nap held off during a backup |
| Files | App container | `~/Library/Application Support/<bundle id>`, `~/Library/Caches/<bundle id>` (not sandboxed) |

Background reality on iOS: MTProto uploads can't use background `URLSession`, so long backups run while the app is
open, during a continued-processing task (iOS 26+) with system progress UI, or during overnight processing tasks while
charging. The App Intent uploads for the time iOS allows, then the next run continues.
