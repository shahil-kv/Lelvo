# Memvo cloud format, version 1

This is the contract for every app that reads or writes a Memvo library: the iOS and Mac apps in this repository, and any compatible app someone else writes. A library written by one **must** be readable by all. If an implementation disagrees with this document, the implementation is wrong. Test vectors live in [`docs/test-vectors/`](test-vectors/), and every implementation's unit tests must pass them.

The app was called CloudGallery when this format was defined. Its identifiers (`#cloudgallery-library`, `CG1:`,
`cg:1`, the `CloudGallery … v1` key-derivation labels) are part of the format and never change with the app's name.

All integers are unsigned and big-endian unless noted otherwise. "UTF-8" always means NFC-normalised UTF-8.

---

## 1. The library

- A library is one **private Telegram channel** owned by the user. The default title is `Memvo Library`; the user can pick any existing channel instead.
- The library is identified by a **header** string:
  - plain library: `cg:1`
  - end-to-end encrypted library: `cg:1;e2e:1;it:<iterations>;s:<salt-b64>;kc:<keycheck-b64>`

  `s` is the 16-byte PBKDF2 salt and `kc` the 16-byte key-check value (§6.1), both standard Base64 with padding.
- The header is written in two places. Readers check them in this order:
  1. a pinned **text message** whose text starts with `#cloudgallery-library ` followed by the header;
  2. the channel **description** (one line beginning with `cg:1`).
- Library flags never change after creation. Switching encryption on or off means creating a new library.

## 2. Items and resources

An **item** is what the user sees as one photo or video. It has a random UUID `id` (lowercase, 36 characters) and one or more **resources**, each stored as one or more document messages.

| Item kind `k` | Required resources (`r`) |
|---|---|
| `p` photo | `o` |
| `v` video | `o` |
| `l` Live Photo | `o` (still) + `pv` (paired video) |

Optional resources:
- `t`: encrypted thumbnail (E2E libraries only, §4)
- `sp`: smooth-streaming copy, a 1080p HEVC preview of a large or high-bitrate video, with its `moov` box first (always optional; the original is never replaced; it never counts towards an item being complete). Its caption describes the copy itself: `h`, `s`, `n`, `wh` and `c` are the copy's.
- `d`: screen copy of a photo (`k` `p` or `l`): a JPEG of what Photos shows (the edit, if any), at most 2048 px on the long side, made only for big or RAW photos so viewers can show it before the original has downloaded (always optional; the original is never replaced; it never counts towards an item being complete). Its caption describes the copy itself: `h`, `s`, `n`, `wh` and `m` are the copy's. Readers that don't know the role skip the message.
- `ad`: the edit's adjustment data as Photos stores it (`Adjustments.plist`), when the item was edited; `ad2`: its secondary data (`AdjustmentsSecondary.data`) when Photos has one. Lets a restore keep the edit in Photos.
- `ra`: the RAW of a RAW + JPEG pair (the JPEG is `o`).
- `epv`: the edited paired video of an edited Live Photo.
- `md`: metadata that doesn't fit the caption, as compact JSON (`{"a":["Album", …]}` today). Readers merge its fields into the original's caption metadata; a field in `md` wins over the same field in the caption.
- `e`: edited version (Photos' rendered edit: crop, filter, trim…) when the item was edited; required when the original's caption has `ed: 1`. The original is always stored untouched as `o`.

## 3. Messages

Each resource (or each part of a split resource, §5) is **one message** in the channel:

- Content: a **document**. Send it with content-type detection disabled: TDLib `inputMessageDocument.disable_content_type_detection = true`.
- File: the original bytes, **bit for bit** (or their CGFE ciphertext in E2E libraries). Never recompress or re-encode them; EXIF, GPS, HEIC, HEVC, HDR and Dolby Vision metadata survive.
- File name on Telegram:
  - plain library: the original file name (`IMG_0001.HEIC`); split parts append `.partNNN` (3 digits, 1-based)
  - E2E library: `<id>.<r>.cge`, or `<id>.<r>.pNNN.cge` for split parts
- Thumbnail (plain libraries): attach a JPEG of at most 320 px on the long side and under 200 KB as the document thumbnail (TDLib `inputThumbnail`). For videos, use a frame about 1 s in (or the first frame).
- Caption: the metadata line (§3.1).

### 3.1 Caption

- Plain library: `CG1:` followed by compact JSON (no whitespace).
- E2E library: `CG1E:` followed by Base64 of `nonce(12) ‖ ciphertext ‖ tag(16)`, the AES-256-GCM encryption of the same compact JSON (§6.3).
- The whole caption must be at most **1000 characters**. If it is too long, writers move `a` into an `md` resource (§2), then drop `c`, then truncate `n` keeping its extension. (Writers before `md` dropped `a`.)
- Readers **ignore unknown fields** and ignore messages whose caption doesn't start with `CG1:` or `CG1E:`.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `v` | int | ✓ | Format version. Always `1`. |
| `id` | string | ✓ | Item UUID, shared by every resource and part of the item. |
| `r` | string | ✓ | Resource role: `o`, `pv`, `t`, `sp`, `e`, `d`, `ad`, `ad2`, `ra`, `epv`, `md`. |
| `k` | string | ✓ | Item kind: `p`, `v`, `l`. |
| `h` | string | ✓ | SHA-256 (lowercase hex) of this resource's **original plaintext** bytes. The same on every part. |
| `n` | string | ✓ | Original file name. |
| `m` | string |  | MIME type of the original. |
| `s` | int | ✓ | Size in bytes of the original plaintext resource (whole file, not the part). |
| `t` | int |  | Capture time, Unix seconds UTC. |
| `tz` | int |  | Capture time-zone offset from UTC, in minutes. |
| `g` | [num, num] or [num, num, num] |  | Latitude, longitude, optional altitude in metres; 6 decimal places. |
| `wh` | [int, int] |  | Pixel width and height (display orientation). |
| `d` | num |  | Duration in seconds (videos and `pv`). |
| `c` | string |  | Video codec: `hevc`, `h264`, `prores`, `av1`, … |
| `hdr` | int |  | `0` SDR, `1` HDR10/HLG, `2` Dolby Vision. |
| `a` | [string] |  | Album names at backup time. |
| `fav` | int |  | `1` if marked favourite. |
| `p` | [int, int, int] |  | Split info: part index (0-based), part count, part size in bytes of the **uploaded** stream (§5). |
| `e` | int |  | `1` if the file content is CGFE ciphertext (§6.2). Always present in E2E libraries. |
| `src` | string |  | Writer, informational only: `ios` (the iOS and Mac apps), or another implementation's name. |
| `l` | string |  | Photos/MediaStore local id of the source asset on the uploading device. Lets a reinstall on that device re-link items exactly (otherwise: name + `t` + `wh`). Dropped before `n` is truncated when the caption is too long. |
| `ed` | int |  | On the original (`r: "o"`): `1` when the item also has an edited version stored as role `e`. Lets readers detect a missing edit. |
| `hid` | int |  | `1` if the item was hidden in Photos. Readers don't show hidden items in their timeline and restore them hidden. |

Example (plain):

```
CG1:{"v":1,"id":"0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10","r":"o","k":"v","h":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","n":"IMG_4821.MOV","m":"video/quicktime","s":734003200,"t":1729677600,"tz":330,"g":[12.971599,77.594566],"wh":[3840,2160],"d":63.2,"c":"hevc","hdr":2,"src":"ios"}
```

## 4. Thumbnails

- Plain libraries: the Telegram document thumbnail (§3) is the thumbnail. Clients download it through the document's `thumbnail.file`.
- E2E libraries: Telegram must not see image content, so there is no document thumbnail. Instead, upload one extra message per item with `r:"t"`, whose file is the CGFE-encrypted 320 px JPEG. Its caption follows §3.1 with `h`/`s` describing the JPEG.

## 5. Split files

- Per-file upload limit `L`: 2,000 MiB (2,097,152,000 bytes), or 4,000 MiB with Telegram Premium. Read it from TDLib option `premium_upload_limit` / `is_premium`, and fall back to 2,000 MiB.
- If the uploaded stream (the plaintext, or the CGFE ciphertext in E2E) is larger than `L`, cut it into parts of exactly `ps` bytes, where `ps = L − 1 MiB` rounded down to a multiple of 1 MiB. Only the last part may be shorter.
- Every part is its own message with the same `id`, `r`, `h` and `s`, and `p = [index, count, ps]`.
- Readers treat the parts as one continuous byte stream: stream offset `x` lives in part `x / ps` at offset `x mod ps`. A read range that crosses a part boundary is served from both parts.
- For E2E files, the split applies to the **ciphertext**, so decryption is unaffected (§6.2).

## 6. End-to-end encryption

### 6.1 Master key

- `master = PBKDF2-HMAC-SHA256(password = NFC-UTF-8(passphrase), salt = s, iterations = it, dkLen = 32)`.
- New libraries use `it = 600000` and a random 16-byte salt. Readers accept any `it ≥ 100000`.
- Key check: `kc = HMAC-SHA256(master, UTF-8("CloudGallery key check v1"))[0..<16]`. A wrong passphrase is detected by comparing `kc` before any decryption.
- The master key is stored only in the platform's secure storage (the Keychain on Apple platforms). A lost passphrase means lost data; apps must say so plainly at library creation.

### 6.2 File content: CGFE (chunked AES-256-GCM)

```
header  = "CGFE" (4) | version = 0x01 (1) | chunkSize (UInt32 BE, 4) | fileSalt (16)      → 25 bytes
chunk_i = nonce (12, random) | ciphertext (chunkSize bytes, or fewer for the last) | tag (16)
file    = header | chunk_0 | chunk_1 | … | chunk_last
```

- `chunkSize` is 1,048,576 (1 MiB) for new files, and 262,144 (256 KiB) for fast versions (`r: "sp"`), which are
  streamed and can start playing after a smaller first chunk. Readers take the size from the header and accept any
  value from 4 KiB to 64 MiB.
- Per-file key: `fk = HKDF-SHA256(ikm = master, salt = fileSalt, info = UTF-8("CloudGallery file v1"), L = 32)`.
- Additional authenticated data for chunk `i`: `header (25 bytes) | i (UInt64 BE) | final (1 byte: 0x01 if last chunk, else 0x00)`.
- An empty plaintext produces exactly one final chunk with empty ciphertext.
- **Random access:** chunk `i` starts at ciphertext offset `25 + i × (chunkSize + 28)`. Given the ciphertext size `C`, the chunk count is `n = ceil((C − 25) / (chunkSize + 28))` and the last index is `n − 1`. Plaintext offset `x` is in chunk `x / chunkSize`. Players decrypt only the chunks they need.
- Plaintext size = `C − 25 − n × 28`.

### 6.3 Captions

- `ck = HKDF-SHA256(ikm = master, salt = 32 zero bytes, info = UTF-8("CloudGallery caption v1"), L = 32)`.
- `caption = "CG1E:" + Base64(nonce(12) ‖ AES-GCM(ck, nonce, json, aad = UTF-8("CG1E")) ‖ tag(16))`.

## 7. Reading a library (restore)

1. Resolve the channel and read the header (§1). For E2E, ask for the passphrase and verify `kc`.
2. Page through **all** history with `getChatHistory` (newest to oldest, 100 per page) and parse each document message with a CG caption.
3. Group by `id`, then `r`, then part index. If the same `(id, r, part)` appears more than once, keep the message with the **lowest message ID**; the others are orphans. An `id` with only optional resources (`d`, `sp`, `t`, `ad`, `ad2`, `ra`, `epv`, `md`) and no `o` is left over from a delete by an older reader: its messages are orphans too, not an item.
4. An item is **complete** when every required resource (§2) is present and, for split resources, parts `0..count−1` all exist with matching `h`. Incomplete items are shown as "incomplete in cloud" and never offered for Free Up Space.
5. The local database is only a cache of this. Deleting it never loses data.

## 8. Writing rules

- An item is "backed up" only after Telegram confirms every required message (`updateMessageSendSucceeded`) and each document's size equals the uploaded stream size (or part size).
- De-duplicate before uploading: platform asset ID first, then `h` of the `o` resource against the local index (which mirrors the channel).
- Respect `FLOOD_WAIT_X` by waiting X seconds. Run at most 2 uploads at once. Use one account only.
- Deleting from the cloud deletes every message of the item (all resources and parts).

## 9. Compatibility with the v1.0 iOS bot format

iOS 1.0 uploaded with a bot, with captions `#cloudgallery id:… role:…` and a pinned encrypted index (`cloudgallery-index.cgx`). Those messages are **not** format 1. The iOS app offers a one-time import: it reads the pinned index with the old passphrase and re-captions nothing. It only links the old messages so they show in the gallery, and lists them as "legacy" until re-uploaded.
