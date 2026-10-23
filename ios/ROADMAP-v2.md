# CloudGallery iOS: Version 2 roadmap (TDLib, your own account)

Version 1 uses the Bot API, which caps files at **50 MB up / 20 MB down** and can't read chat history. Version 2 logs in as **your own Telegram account** through [TDLib](https://core.telegram.org/tdlib) using the [TDLibKit](https://github.com/Swiftgram/TDLibKit) Swift package. That lifts those limits while keeping the same channel and the same encrypted index.

## Goals

| | v1 (Bot API) | v2 (TDLib, user account) |
|---|---|---|
| Max upload | 50 MB | **2 GB** (4 GB with Telegram Premium) |
| Max download / view | 20 MB | 2 GB / 4 GB |
| Video playback | Full download, ≤ 20 MB | **Streaming** (play while downloading) |
| Index source of truth | Pinned encrypted index | Pinned index **plus** rebuild from channel history |
| Rate limits | ~1 msg/s per chat | MTProto flood-wait (TDLib handles `FLOOD_WAIT_x`) |

## Architecture

```
CloudGalleryCore (unchanged: crypto, index, cache, dedupe)
        │
        ├── TransportProtocol  ← new abstraction
        │      ├── BotTransport     (v1, existing TelegramClient + background URLSession)
        │      └── TDLibTransport   (v2, TDLibKit)
        │
App: BackupEngine / CloudMediaService / IndexSyncService talk to TransportProtocol only.
```

1. **Extract `TransportProtocol`** with `upload(file:caption:) -> RemoteFile`, `download(remote:) -> URL`, `stream(remote:) -> AVAsset`, `delete`, `pin`, `pinnedMessage`, `history(fromMessageId:)`.
2. **Extend `RemoteFile`** with an optional `tdRemoteId` (TDLib's persistent `remote.id`) and a `transport` field. Bot `file_id`s and TDLib remote IDs are **not interchangeable**, so v2 resolves files by `(chatId, messageId)` via `getMessage`, which works for any message regardless of who posted it.
3. **TDLib setup**: add `TDLibKit` through SwiftPM in `project.yml`, and keep the TDLib database in Application Support (excluded from iCloud backup). `api_id`/`api_hash` come from my.telegram.org and are entered by the user at login (never committed).

## Login flow

`setTdlibParameters` → phone number → code (SMS/Telegram) → optional 2FA password → `authorizationStateReady`. The session is stored in TDLib's encrypted database, with the database key in the Keychain. Add a **Log out / revoke session** button.

## Uploads up to 2 GB / 4 GB

- `sendMessage` with `inputMessageDocument` and `disable_content_type_detection = true`. Track progress through `updateFile` (`remote.uploadedSize`).
- TDLib uploads in 512 KB parts and resumes after interruption. When iOS suspends the app, a `BGContinuedProcessingTask` (iOS 26+) keeps a user-started backup alive, and a `BGProcessingTask` resumes it overnight. (TDLib uses its own sockets, not background `URLSession`.)
- Items currently marked `tooLarge` are re-queued automatically when the user switches to v2.
- `isPremium` from `getMe` decides between the 2 GB and 4 GB limits.

## Streaming video

- `downloadFile(priority:offset:limit:synchronous:false)` fetches only the byte ranges being played.
- An `AVAssetResourceLoaderDelegate` with a custom URL scheme (`tgstream://`) serves AVPlayer range requests from the partially downloaded TDLib file, waiting on `updateFile` for missing ranges.
- E2E-encrypted videos: v1's chunked format (1 MB chunks, per-chunk authentication) supports random access, so chunk *n* can be decrypted on its own. The resource loader maps plaintext ranges to ciphertext chunks.

## Rebuilding the index from channel history

v1 captions every upload: `#cloudgallery id:<uuid> role:<original|pairedVideo|thumbnail> sha256:<hex> date:<iso>` (E2E items: `e2e:1` with no hash or date). With a user account v2 can:

1. `getChatHistory` (paged, oldest first) over the whole channel.
2. Group messages by `id:`; rebuild `LibraryItem`s from captions plus document metadata.
3. Merge with the pinned index (the index wins for fields captions don't have, like location and dimensions). History wins for existence: items whose messages were deleted are dropped.
4. Re-pin a fresh index. This also repairs a lost passphrase *for non-E2E items* (E2E content still needs the passphrase).

## Migrating from v1 bot data

1. v2 reads the existing pinned index with the same passphrase. No re-upload is needed; everything stays in the same channel.
2. Background job: for each item, `getMessage(chatId, messageId)` → store `tdRemoteId`. Bot `file_id`s are kept for rollback.
3. Re-queue `tooLarge` items for upload through TDLib.
4. Items in the 20–50 MB range become viewable and verifiable, so they are eligible for Free Up Space after verification.
5. The bot stays an admin, so v1 builds keep working with the same channel. The index format version goes to 2 with new optional fields only, so v1 can still decode it.

## Risks and mitigations

- **Account safety**: automated user-account uploads must respect `FLOOD_WAIT`. Keep the ~1 msg/s pacing, never parallelise sends into one chat, and add a daily cap setting.
- **App size**: TDLib adds about 30 MB. Ship v2 as a separate target/scheme so the Bot-only build stays small.
- **Login codes**: never log or store them, and redact phone numbers in logs.
- **Terms**: using your own account for personal backup within Telegram's limits; no sharing of sessions.

## Milestones

1. `TransportProtocol` refactor with v1 behind it (no behaviour change, tests pass).
2. TDLib login + read-only browsing of the channel (viewing > 20 MB files, streaming).
3. Large uploads + re-queue of `tooLarge`.
4. History-based index rebuild + migration job.
5. Free Up Space for 20 MB+ items after TDLib verification.
