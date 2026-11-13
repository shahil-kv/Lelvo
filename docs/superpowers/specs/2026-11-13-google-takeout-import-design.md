# Import from Google Photos and Google Drive (Takeout) — design

Status: approved by the owner on 2026-11-13.

## Why

People switching to Lelvo usually have years of photos in Google Photos or Google Drive. Google's APIs can't read a
whole library any more: the Photos Library API only sees what the app itself uploaded (since March 2025), and reading
all of Drive needs a restricted scope with a paid yearly security assessment. Google Takeout is the one complete,
free way out. Today the only path is "unzip, fix the dates with a third-party tool, import into Apple Photos, let Lelvo
back it up", which needs room for the whole library on the device. Most people switching are switching *because*
they're out of space.

## What it is

A **Takeout importer**: the user picks Takeout zip files (or an unzipped Takeout folder), and Lelvo uploads the photos
and videos inside straight to their Telegram library, as normal cloud-only items with the right date, place, albums
and favourite. Nothing is added to Apple Photos or the Android gallery.

Two entries under **Backup → Tools**: **Import from Google Photos** and **Import from Google Drive**. Both open a
step-by-step guide (how to request the Takeout, which options to pick, how to download, how to import), then the import
screen.

## Goals

- Import every photo and video in a Takeout export, with the capture date and place Google kept in its JSON files.
- Use as little device space as possible: **never unzip to disk**. Read each file out of the zip, upload it, delete the
  temporary copy, go on. With 2 GB zips (what the guide tells people to pick) the import needs about **2 GB for the zip
  plus room for the largest single file**.
- Let people do it one zip at a time: import a zip, delete it, download the next. The import remembers where it was.
- Show it in the timeline like any other cloud item: dates right, places on the map, albums, favourites, Live Photos
  playing.
- Skip what's already in the library (same SHA-256), so importing twice or importing photos already backed up from the
  phone uploads nothing again.

## Non-goals

- Documents, PDFs, Google Docs, audio, anything that isn't a photo or video. They're counted and listed as "Not
  imported (not a photo or video)", never uploaded.
- Signing in to Google, or reading Google Photos / Drive through their APIs. No Google SDK, no Google account.
- Unzipping "in the cloud". Lelvo has no servers (and won't). The zip is read on the device, one file at a time.
- `.tgz` exports. The guide says to choose `.zip`; a `.tgz` gets a plain message saying to request a zip export.
- Importing people/faces, descriptions and comments from Google. (Description could later go into the `md` resource;
  not now.)
- Background imports on iOS. The import runs while the app is open (the screen stays on, like a first backup), and
  continues where it stopped when the app comes back.

## Anti-goals (would make it a failure even if it works)

- Any change to how phone backup behaves, or any extra risk to it. `BackupEngine.process` isn't modified.
- Any change to the cloud format. Imported items must be ordinary format 1 items that every existing reader — iOS, Mac,
  Android, restore, older app versions — already understands.
- More than two uploads at once *in total* (backup + import together), or ignoring `FLOOD_WAIT`.
- Deleting anything the user didn't explicitly confirm. The importer never deletes zips on its own.
- Photos landing on "today" because a date wasn't found and nobody noticed.
- Filling the device: the importer checks free space before each file and stops with a clear message instead.

## Constraints (from AGENTS.md)

- No new dependencies. Zip reading is our own small reader in `LelvoCore` (Apple: Foundation `FileHandle` + the
  system `Compression` framework for DEFLATE; Android later: `java.util.zip.Inflater`).
- Storage format unchanged (format 1, `docs/CLOUD_FORMAT.md`). Libraries are end-to-end encrypted on `main`, so every
  imported file goes through CGFE like any backup.
- Nothing heavy on the main thread: zip reading, hashing, inflating, metadata parsing and uploads run off the main actor.
- No personal data in logs: log counts and sizes, never file paths from the user's Takeout beyond the file name the
  existing logs already use.
- `Shared/` builds for iOS and macOS; the folder/zip picker differs per platform.
- Logic gets unit tests in `Packages/LelvoCore` (zip reader, sidecar matching, metadata choice, Live Photo pairing).

## How it works

### What a Takeout looks like (what the code must handle)

- Zips named `takeout-20261113T081500Z-001.zip`, `-002.zip`, … Inside: `Takeout/Google Photos/<folder>/…` or
  `Takeout/Drive/<path>/…`. Folder names are localised ("Google Fotos").
- Google Photos folders: `Photos from 2019/` (one per year) and one folder per album. **The same photo appears in its
  year folder and in each album folder.** Album folders contain a `metadata.json` with the album `title`.
- Each photo/video has a JSON sidecar with `photoTakenTime.timestamp` (Unix seconds, UTC), `geoData`
  `{latitude, longitude, altitude}` (all `0.0` when unknown), `geoDataExif`, `favorited`, `title` (original file name).
- Sidecar names vary and must be matched carefully:
  - `IMG_1234.jpg.json` (older exports) and `IMG_1234.jpg.supplemental-metadata.json` (2024 onwards)
  - truncated to 51 characters in total, so `…supplemental-metadata.json` becomes `…supplemental-met.json`,
    `…suppl.json`, etc., and long media names are cut too
  - duplicates: `IMG_1234(1).jpg` pairs with `IMG_1234.jpg(1).json` / `IMG_1234.jpg.supplemental-metadata(1).json`
  - edited copies `IMG_1234-edited.jpg` (localised: `-bearbeitet`, `-modifié`, `-editado`, …) share the original's sidecar
- Live Photos from an iPhone: `IMG_1234.HEIC` + `IMG_1234.MOV` in the same folder. Pixel motion photos are a single
  JPEG (`PXL_…MP.jpg`) with the video inside, or `…MP.jpg` + `…MP` / `…MP.mp4`.
- A sidecar can be in a **different zip** from its photo.
- Zips over 4 GB use ZIP64. Drive exports have no sidecars.

### Pipeline

1. **Add files.** The user picks one or more zips, or an unzipped Takeout folder (Files on iPhone, which also covers
   USB drives and SD-card readers; Finder on Mac). Lelvo keeps a security-scoped bookmark so it can resume later.
2. **Catalogue (seconds, reads only the end of each zip).** Read each zip's central directory: every entry's path,
   size, CRC-32 and compression method, without extracting anything. Store the entries in a local `import_entries`
   table (local SQLite only, like the other local tables). Read the small JSON sidecars and album `metadata.json` files
   (a few KB each) to build the metadata for each photo.
3. **Plan items** (pure logic in `LelvoCore`, fully unit-tested):
   - classify entries: photo, video, sidecar, album metadata, other (skipped)
   - match each media entry to its sidecar (rules above)
   - group copies of the same photo across year and album folders by `(title or name, size, CRC-32)` → one item,
     albums = the album folders it appeared in
   - pair Live Photos (same folder, same stem, image + `.MOV`) → kind `l` with role `pv`
   - pair `-edited` copies with their original → role `e` on the original, with `ed: 1` (format 1 already has this)
   - date: sidecar `photoTakenTime` → EXIF `DateTimeOriginal` / video creation date (read later from the file) →
     **no date: the item waits** (see below)
   - place: sidecar `geoData` if not `0,0` → `geoDataExif` if not `0,0` → GPS in the file (it's in the original anyway)
   - favourite: sidecar `favorited`
4. **Import one item at a time** through the same two upload slots as backup:
   - check free space for this item (largest resource + one encrypted part + the usual margin)
   - stream the entry out of the zip into a temporary file, computing SHA-256 and checking CRC-32 on the way
   - same SHA-256 already backed up → skip, count as "already in your library"
   - read size, duration, codec, HDR, EXIF date/time zone and a thumbnail from the temporary file
   - build a normal format 1 caption (`t`, `tz`, `g`, `wh`, `d`, `c`, `hdr`, `a`, `fav`; no `l`, since it isn't on the
     device) and upload with `CloudUploader`, exactly as a backup does (CGFE, split parts, size check)
   - save the item as `backedUp` only when every required part is confirmed with the expected size; it then shows as
     "Only in the cloud"
   - delete the temporary file
5. **After a zip is done**, show "Done. You can delete takeout-…-001.zip to free 2 GB." with a Delete button (confirmed
   by the user, and only if every media entry in that zip is backed up, already in the library, or deliberately
   skipped). Then "Add the next zip".

### Items without a date

Most sidecars are in the same zip as their photo, and camera photos have EXIF dates anyway. A photo with neither a
sidecar yet nor a date in the file **isn't uploaded straight away**: it waits as "Waiting for its details", because
its sidecar may be in a zip that hasn't been added yet. When the user taps **That's all my files**, waiting items
upload with the zip entry's modified date and are listed afterwards as "Imported without a date from Google" so the
user can check them.

### Sharing the upload slots with backup

`BackupEngine` owns the two upload slots, the pacing between upload starts and the `FLOOD_WAIT` pause. The importer
gets those through a small internal API on `BackupEngine` (lane slots, without the note slot's priority; see "Sharing
with backup, and the settings" below), so backup + import together never exceed two uploads, and a `FLOOD_WAIT` pauses
both. Nothing in `process` changes.

### Resume

Each import entry has a status (`pending`, `waitingForDetails`, `uploading`, `done`, `duplicate`, `skipped`, `failed`)
and, once started, the Lelvo item id. An interrupted item resumes like a backup: `CloudUploader` skips confirmed parts;
the entry is re-extracted (same bytes, same SHA-256), so the encrypted resume point still matches. If the zip is gone
when resuming, the screen says which zip to add back.

### Space, in numbers (shown on the import screen before Start)

Needed free space ≈ (zip, if it's on this device) + largest file in it + min(largest file, one Telegram part) + 300 MB
margin. The guide recommends 2 GB zips, so most imports need about 3–5 GB free. If the zips are on a USB drive or SD
card, only the temporary file counts.

### Things that arrive in a later zip

Takeout fills zips folder by folder, so a pair is split only when it falls on a zip boundary, but it does happen.
Decided (builder's call, for the owner to check):

- **Album copy or favourite in a later zip**: the photo is already imported, so its SHA-256 matches. Instead of
  dropping the album quietly, add it with the existing album and favourite notes (`LibraryStore.queueMetaChanges`,
  `docs/CLOUD_FORMAT.md` §7.3). That's the same thing as the user adding it to an album by hand, and it needs no format
  change.
- **Photos already in the library from the phone** (same SHA-256): the owner decided Google's albums and favourite
  are added to them the same way, only ever adding, never removing.
- **Live Photo video or `-edited` copy in a later zip than its photo**: imported as its own video or photo, and listed
  as "Imported separately". Joining them afterwards would mean rewriting the original's caption, which the importer
  never does.

### Which files count

Photos: `jpg jpeg heic heif png gif webp avif tif tiff dng cr2 cr3 nef arw orf rw2 raf srw`. Videos: `mov mp4 m4v 3gp
3g2 mkv avi wmv mts m2ts webm mpg mpeg` and Pixel's bare `.MP`. Pixel's `…MP.jpg` + `…MP`/`…MP.mp4` pair: the second
file is imported as its own video (pairing it as `pv` would make a Live Photo that Apple Photos can't restore).
Everything else is "not a photo or video". The delete-zip prompt lists every entry in that zip that wasn't uploaded
or wasn't already in the library, so nothing is lost without the user seeing it.

**Files the device can't decode** (an old codec, a RAW the system doesn't know): the original is still uploaded bit for
bit. An end-to-end encrypted item needs a thumbnail (`t`) to count as backed up, so these get a plain placeholder
thumbnail (a grey square with a photo or video symbol). They show in the timeline and can be downloaded.

### Sharing with backup, and the settings

- The importer uses **lane** slots, like backup, never the note slot's priority. With no backup running it uses both
  slots. When a backup run starts, the import steps down to one slot, so a phone backup is never held back.
- `FLOOD_WAIT` pauses both. Pausing the backup doesn't pause the import, and the other way round: each has its own
  Pause button.
- **Wi-Fi only** applies to the import too (it moves tens of gigabytes). While it's waiting, the import screen says
  "Waiting for Wi-Fi (Wi-Fi only is on)", which is the backup's existing message. **Charging only** doesn't apply,
  because the user starts the import themselves and watches it.

## UI

Follows Apple's own apps: a grouped form, system controls, plain short sentences, no exclamation marks, Dynamic Type,
VoiceOver labels. Mac uses the same views inside `MacBackupView`'s Tools.

1. **Backup → Tools**: "Import from Google Photos" (`photo.stack`), "Import from Google Drive" (`folder`).
2. **Guide** (per source), numbered steps, each one or two sentences, with an "Open Google Takeout" button:
   1. Open Google Takeout and sign in with the Google account that has your photos.
   2. Tap **Deselect all**, then select only **Google Photos** (or **Drive**).
   3. Choose **Send download link via email**, **Export once**, file type **.zip**, size **2 GB**.
   4. Wait for Google's email. It can take a few hours or a few days for a big library.
   5. Download the first zip into Files (or onto a USB drive or SD card if your phone is full).
   6. Come back here and tap **Choose files**.
   7. When Lelvo says a zip is done, delete it and download the next one.
   Footer notes: Wi-Fi recommended; keep Lelvo open while it imports; Takeout links expire after 7 days, so download
   them in time (you can always request a new export).
3. **Import screen**: Choose files · list of added zips/folders with a status each · summary (photos, videos, already
   in your library, not photos or videos, waiting for details) · space needed vs free · **Start import** /
   **Pause** · live progress using the existing lanes view · per-zip "Done — Delete zip" · "That's all my files".
4. **Done**: "Imported 4,210 photos and 380 videos. 96 were already in your library." with links to the lists
   (failed, imported without a date, not imported).

Error messages are `LocalizedError`s with what to do next, for example: "This file is a .tgz export. Request a new
export from Google Takeout and choose .zip." · "There isn't enough space to import IMG_1234.MOV. Free up 1.2 GB or
move the zip to a USB drive." · "takeout-…-003.zip is no longer where it was. Choose it again to continue."

## Platforms and order

1. **iOS + Mac** (one shared implementation in `Shared/`, core logic in `LelvoCore`).
2. **Android** afterwards, same rules: a Kotlin zip reader over a seekable `ParcelFileDescriptor` (works with SD cards
   and USB drives through the system folder picker), `java.util.zip.Inflater`, and the same matching rules ported to
   `android/core` with the same test cases.

## Known limitations (said in the guide's FAQ)

- Photos saved in Google's "Storage saver" quality are smaller copies, so they won't match the originals on the phone
  and can appear twice. The existing Duplicates tool only catches exact copies.
- Google's export of edited photos is the edit only for some items; whatever Google gives is imported.
- Pixel motion photos import as one JPEG with the video inside (bit for bit), shown as a still for now.
- A Live Photo or edited copy split across two zips imports as two separate items.

## Left to the builder

- Exact file and type names, as long as they match the surrounding code.
- How the import screen shows per-lane progress (reuse `BackupActivity` if it fits).
- The ZIP reader's internal structure (it must handle stored + DEFLATE entries, ZIP64, and data descriptors).
- Test fixtures: generate small zips in the tests rather than committing binary files.
