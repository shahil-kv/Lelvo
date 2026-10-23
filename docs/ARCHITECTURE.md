# Architecture

Two native apps share one storage contract ([CLOUD_FORMAT.md](CLOUD_FORMAT.md)) and the same design. Each signs in to the user's **own Telegram account through TDLib** and stores everything in one private channel.

```
                ┌──────────────── Telegram (user account, MTProto) ────────────────┐
                │  Private channel "CloudGallery Library"                           │
                │  one document message per resource/part, caption = CG1 JSON        │
                └──────────────────────────────▲───────────────────────────────────┘
                                               │ TDLib (TDLibKit on iOS, tdlib JNI on Android)
 ┌─────────────────────────────────────────────┴──────────────────────────────────────────┐
 │ TelegramService     login (phone, code, 2FA), FLOOD_WAIT, upload/download, history      │
 │ LibraryService      create/pick channel, header, restore = scan history → index         │
 │ BackupEngine        job queue: pending → uploading → verified | failed(reason)          │
 │ MediaReader         byte-range reads over parts + CGFE decryption (streaming, viewer)   │
 │ Caches              thumbnails (300 MB) · media (1 GB) · TDLib storage optimizer         │
 │ Index DB            local cache of the channel (SQLite / Room), never the source of truth│
 └─────────────────────────────────────────────▲──────────────────────────────────────────┘
                                               │
 ┌─────────────────────────────────────────────┴──────────────────────────────────────────┐
 │ UI: timeline (local + cloud), albums, viewer (photo/Live/video), selection, settings    │
 │ iOS: SwiftUI · PhotoKit · AVPlayer + AVAssetResourceLoader · App Intents · BGTasks       │
 │ Android: Compose · MediaStore · Media3 ExoPlayer + DataSource · WorkManager FG service   │
 └─────────────────────────────────────────────────────────────────────────────────────────┘
```

## Shared principles

1. **The channel is the truth.** The local DB is a cache that is rebuilt by scanning history. Counts come from verified items.
2. **Bit-for-bit originals** are sent as documents with content-type detection disabled.
3. **Nothing is "backed up" until verified**: Telegram has confirmed the message and the document size equals the uploaded stream size.
4. **Resumable and durable**: job states live in the DB; a killed app resumes where it stopped. TDLib resumes partially uploaded files.
5. **Honest limits**: `FLOOD_WAIT` is honoured, there are at most 2 concurrent uploads, and there is one account.
6. **Small caches**: LRU caps plus TDLib `optimizeStorage`. Viewing never permanently uses storage.
7. **No secrets in code or logs**: `api_id`/`api_hash` and the passphrase are entered by the user and stored in secure storage; logs are redacted.

## Job queue state machine

```
          enqueue                  start                  sent + size ok
 (none) ─────────▶ pending ─────────────▶ uploading ─────────────────────▶ verified
                     ▲  ▲                    │  │
          retry/     │  └──── FLOOD_WAIT ────┘  │ error
          resume     │       (wait, same state) ▼
                     └────────────────────── failed(reason, attempts)
```

- `uploading → pending` on app kill: TDLib may still finish the send, so the engine first reconciles pending sends (`updateMessageSendSucceeded` / the history scan) before re-uploading.
- `failed` is retried automatically with exponential backoff up to 5 attempts, then waits for a manual **Retry**.
- `verified` items with a local asset are eligible for Free Up Space.

## Streaming

`MediaReader.read(item, resource, offset, length)`:
1. Map the plaintext range to the stream range (identity for plain files; chunk-aligned ciphertext range for CGFE).
2. Map the stream range to parts (`p` info).
3. For each part, call TDLib `downloadFile(file_id, priority 32, offset, limit, synchronous=false)` and wait until `downloaded_prefix_size` covers the range (`getFileDownloadedPrefixSize`), then read the bytes with `readFilePart`.
4. Decrypt the needed chunks and slice them to the requested range.

- iOS: an `AVAssetResourceLoaderDelegate` on a `cgstream://` URL answers content-information and data requests with `MediaReader`.
- Android: a Media3 `DataSource` with the same mapping.

Seeking works even when the MOV `moov` atom sits at the end of the file, because the player requests that range first.

## Platform specifics

| | iOS (Phase 1) | Android (Phase 2) |
|---|---|---|
| TDLib | TDLibKit (SPM, prebuilt xcframework) | tdlib JNI `.so` + `TdApi` Java classes |
| DB | SQLite (CloudGalleryCore `LibraryStore`) | Room |
| Background | `BGContinuedProcessingTask` (user-started, progress UI), `BGProcessingTask` (charging, overnight), App Intents | WorkManager + foreground service (dataSync), charging/Wi-Fi constraints |
| Player | AVPlayer + resource loader, PiP, AirPlay | Media3 ExoPlayer, PiP |
| Secure storage | Keychain (this device only) | Android Keystore (AES-GCM wrapped prefs) |
| Delete from device | `PHAssetChangeRequest.deleteAssets` | `MediaStore.createDeleteRequest` / `MANAGE_MEDIA` |

Background reality on iOS: MTProto uploads can't use background `URLSession`, so long backups run while the app is open, during a continued-processing task (iOS 26+) with system progress UI, or during overnight processing tasks while charging. The App Intent prepares items and runs uploads for the time iOS allows, then schedules the rest.
