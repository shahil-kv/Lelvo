# Import from Google Photos and Drive (Takeout) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users pick Google Takeout zips (or an unzipped Takeout folder) and Lelvo uploads every photo and video inside
straight to their Telegram library as normal cloud-only items, without unzipping and without using Apple Photos.

**Architecture:** Pure logic in `LelvoCore/Import/` (zip reading, Google sidecar parsing and matching, item planning,
the local `import_entries` table), all unit-tested. A `TakeoutImporter` service in `Shared/Services/Import/` streams one
entry at a time to a temporary file, de-duplicates by SHA-256, builds a format 1 caption and uploads through the existing
`CloudUploader`, holding one of `BackupEngine`'s two upload slots. SwiftUI guide and import screens under Backup → Tools
on iOS and Mac. Android is a later phase (Task 11).

**Tech Stack:** Swift 6, SwiftUI, Foundation `FileHandle`, `Compression` (raw DEFLATE), CryptoKit, ImageIO,
AVFoundation, SQLite (existing `LibraryStore`), XCTest. Android later: Kotlin, `java.util.zip.Inflater`.

**Spec:** `docs/superpowers/specs/2026-11-13-google-takeout-import-design.md`

## Global Constraints

- No new dependencies (AGENTS.md 7). Zip reading is our own code.
- Cloud format unchanged: imported items are format 1 items (`docs/CLOUD_FORMAT.md`); no new caption keys, no new roles.
- At most two uploads at once across backup and import; `FLOOD_WAIT` pauses both; same 1.5 s spacing between starts.
- `BackupEngine.process(_:lane:isCancelled:)` is not modified.
- Nothing is deleted without the user's confirmation; a zip may only be deleted when every media entry in it is `done`,
  `duplicate` or `skipped`.
- An item counts as imported only when `item.isCompleteInCloud` is true after upload (every part confirmed, expected size).
- Zip reading, inflating, hashing, metadata reading and SQLite run off the main actor; UI updates via `MainActor`.
- Logs through `appLog`; log counts, sizes and file names only, never Takeout folder paths or JSON contents.
- `Shared/` compiles for iOS and macOS; pickers are per platform.
- User-facing text: short sentences, plain words, no exclamation marks, say "your Telegram library".
- Errors shown to users are `LocalizedError`s that say what to do next.
- Only photos and videos are imported. Everything else is counted as "not a photo or video" and never uploaded.
- Guide recommends: Export once, `.zip`, 2 GB, download link by email. Takeout links expire after 7 days.
- Space check per item: largest resource + `min(largest resource, uploadLimit part)` + `CloudUploader.spaceMargin`.
- Commits: `import: …` subject prefix, one commit per task.

## Review Focus

1. **Sidecar in a later zip.** A photo whose JSON is in zip 3 while the photo is in zip 1 must not upload with a wrong
   date when it has no EXIF date; it waits (`waitingForDetails`) and uploads after zip 3 is added. Test in Task 4.
2. **Zip moved or deleted mid-import.** Resuming with a zip gone marks its pending entries as needing that file and the
   screen names it; nothing fails for good. Test in Task 8.
3. **Running out of space mid-import.** The importer stops with `NotEnoughSpaceError` before extracting, the entry stays
   `pending`, and no temporary file is left behind. Test in Task 8.
4. **Backup running at the same time.** Import and backup together never hold more than two slots; a `FLOOD_WAIT`
   during import pauses backup too. Test in Task 6.
5. **Same photo twice** (album folder + year folder, re-importing the same zip, or already backed up from the phone):
   uploaded at most once. Tests in Task 4 (grouping) and Task 8 (SHA-256 skip).

---

### Task 1: Zip reader

**Files:**
- Create: `Packages/LelvoCore/Sources/LelvoCore/Import/ZipArchive.swift`
- Create: `Packages/LelvoCore/Tests/LelvoCoreTests/Support/ZipFixture.swift` (tiny zip writer for tests: stored and
  DEFLATE entries, optional ZIP64 records, optional data descriptors)
- Test: `Packages/LelvoCore/Tests/LelvoCoreTests/ZipArchiveTests.swift`

**Interfaces:**
- Produces:
  - `public struct ZipEntry: Sendable, Equatable { public let path: String; public let compressedSize: Int64; public let size: Int64; public let crc32: UInt32; public let method: UInt16; public let localHeaderOffset: Int64; public let modified: Date? }`
  - `public final class ZipArchive: @unchecked Sendable { public init(url: URL) throws; public let entries: [ZipEntry]; public func extract(_ entry: ZipEntry, to url: URL, progress: ((Int64) -> Void)? = nil) throws -> String /* SHA-256 hex of the plaintext */; public func data(_ entry: ZipEntry, limit: Int64) throws -> Data }`
  - `public enum ZipError: LocalizedError, Equatable { case notAZip, tgz, unsupportedMethod(UInt16), encrypted, crcMismatch(String), truncated }`

- [ ] **Step 1: Write the failing tests**

```swift
func testListsStoredAndDeflatedEntries()      // fixture with a.jpg (stored) + b.json (deflate): entries.map(\.path) == ["a.jpg", "b.json"], sizes match
func testExtractsBitForBitAndReturnsSHA256()   // 3 MB random bytes, deflated: extracted file == input; return == SHA256 hex of input
func testReadsZip64()                         // fixture with ZIP64 end records and 64-bit sizes: entry.size == fixture size
func testDataDescriptorEntries()              // general-purpose bit 3 set: sizes come from the central directory, extract works
func testCRCMismatchThrows()                  // flip one byte of entry data: extract throws .crcMismatch("a.jpg"), destination removed
func testTgzIsRecognised()                    // file starting 1F 8B: init throws .tgz
func testNotAZip()                            // random bytes: init throws .notAZip
func testUTF8Names()                          // "Google Fotos/Fotos von 2019/Bild ü.jpg" round-trips
```

- [ ] **Step 2: Run them and see them fail**

Run: `cd Packages/LelvoCore && swift test --filter ZipArchiveTests`
Expected: FAIL, `ZipArchive` not defined.

- [ ] **Step 3: Implement `ZipArchive`**

Find the end-of-central-directory record by scanning backwards from the end (at most 65,557 bytes), follow the ZIP64
locator when present, read the central directory only. `extract` seeks to the local header, skips its name and extra
field (lengths from the *local* header), and streams in 1 MB chunks: method 0 copies, method 8 inflates with
`compression_stream` and `COMPRESSION_ZLIB` (raw DEFLATE). Hash with CryptoKit `SHA256` and compute CRC-32 while
writing; on mismatch delete the destination and throw. `data(_:limit:)` is for JSON sidecars and refuses entries over
`limit`.

- [ ] **Step 4: Run the tests and see them pass**

Run: `cd Packages/LelvoCore && swift test --filter ZipArchiveTests`
Expected: PASS.

- [ ] **Step 5: Commit** — `import: read Takeout zips without unzipping them`

---

### Task 2: Google sidecar JSON

**Files:**
- Create: `Packages/LelvoCore/Sources/LelvoCore/Import/TakeoutSidecar.swift`
- Test: `Packages/LelvoCore/Tests/LelvoCoreTests/TakeoutSidecarTests.swift`

**Interfaces:**
- Produces: `public struct TakeoutSidecar: Equatable, Sendable { public var title: String?; public var takenAt: Date?; public var latitude: Double?; public var longitude: Double?; public var altitude: Double?; public var favorite: Bool; public static func parse(_ data: Data) -> TakeoutSidecar? }`
  and `public struct TakeoutAlbumMetadata { public var title: String; public static func parse(_ data: Data) -> TakeoutAlbumMetadata? }`

- [ ] **Step 1: Write the failing tests**

```swift
func testParsesTakenTimeAsUTCSeconds()   // "photoTakenTime":{"timestamp":"1562264521"} → takenAt == Date(timeIntervalSince1970: 1562264521)
func testZeroGeoIsNoPlace()              // geoData all 0.0 and geoDataExif all 0.0 → latitude == nil
func testFallsBackToGeoDataExif()        // geoData 0.0, geoDataExif 12.97,77.59 → (12.97, 77.59)
func testFavorited()                     // "favorited": true → favorite == true; missing → false
func testIgnoresUnknownFields()          // people, imageViews, url present → parses
func testAlbumMetadataTitle()            // {"title":"Goa 2019",...} → "Goa 2019"
func testGarbageReturnsNil()             // "not json" → nil
```

- [ ] **Step 2: Run them and see them fail** — `swift test --filter TakeoutSidecarTests`, FAIL.
- [ ] **Step 3: Implement with `JSONDecoder`; `timestamp` is a string in Google's JSON.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit** — `import: read dates, places and favourites from Google's JSON files`

---

### Task 3: Matching media to sidecars

**Files:**
- Create: `Packages/LelvoCore/Sources/LelvoCore/Import/TakeoutMatcher.swift`
- Test: `Packages/LelvoCore/Tests/LelvoCoreTests/TakeoutMatcherTests.swift`

**Interfaces:**
- Produces:
  - `public enum TakeoutFileKind: Sendable { case photo, video, sidecar, albumMetadata, other }`
  - `public enum TakeoutMatcher { public static func kind(ofPath path: String) -> TakeoutFileKind; public static func sidecarCandidates(forMediaPath path: String) -> [String]; public static func originalPath(ofEditedPath path: String) -> String? }`

Photo extensions: `jpg jpeg heic heif png gif webp avif tif tiff dng cr2 cr3 nef arw orf rw2 raf srw`. Video: `mov mp4
m4v 3gp 3g2 mkv avi wmv mts m2ts webm mpg mpeg mp` (Pixel's bare `.MP`). `metadata.json` (and localised names such as `Metadaten.json`,
`métadonnées.json`) in a folder → `albumMetadata`; other `.json` → `sidecar`. Comparison is case-insensitive.

- [ ] **Step 1: Write the failing tests** — each a `XCTAssertTrue(candidates.contains(expected))`:

```swift
"Photos from 2019/IMG_1234.jpg"            → "Photos from 2019/IMG_1234.jpg.json", ".../IMG_1234.jpg.supplemental-metadata.json"
"Photos from 2019/IMG_1234(1).jpg"         → "Photos from 2019/IMG_1234.jpg(1).json", ".../IMG_1234.jpg.supplemental-metadata(1).json"
long name (47 chars + ".jpg")              → the name truncated so the whole sidecar name is 51 characters
".../IMG_1234.jpg.supplemental-metadata.json" truncated → ".supplemental-met.json", ".suppl.json", ".s.json" variants
"Photos from 2019/IMG_1234-edited.jpg"     → originalPath == "Photos from 2019/IMG_1234.jpg"; also "-bearbeitet", "-modifié", "-editado", "-modificato"
"Photos from 2019/PXL_20231010_101010.MP"  → kind == .video
"Goa 2019/metadata.json"                   → kind == .albumMetadata
"Drive/Notes/report.pdf"                   → kind == .other
```

- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** Generate candidates in the order Google's naming generations appeared; truncation keeps the
  total file name at 51 characters including `.json`.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit** — `import: match Takeout photos to their JSON files`

---

### Task 4: Planning items

**Files:**
- Create: `Packages/LelvoCore/Sources/LelvoCore/Import/TakeoutPlanner.swift`
- Test: `Packages/LelvoCore/Tests/LelvoCoreTests/TakeoutPlannerTests.swift`

**Interfaces:**
- Consumes: `ZipEntry` (Task 1), `TakeoutSidecar`, `TakeoutAlbumMetadata` (Task 2), `TakeoutMatcher` (Task 3).
- Produces:
  - `public struct TakeoutSourceEntry: Sendable, Equatable { public var sourceId: String; public var entry: ZipEntry }`
  - `public struct TakeoutPlannedItem: Sendable, Equatable { public var key: String /* stable: lowercased name|size|crc32 of the primary */; public var kind: MediaKind; public var primary: TakeoutSourceEntry; public var pairedVideo: TakeoutSourceEntry?; public var edited: TakeoutSourceEntry?; public var albums: [String]; public var sidecar: TakeoutSidecar?; public var dateSource: DateSource }`
  - `public enum DateSource: String, Sendable { case google, fileWillTell, waiting }`
  - `public struct TakeoutPlan: Sendable { public var items: [TakeoutPlannedItem]; public var skipped: [TakeoutSourceEntry]; public var photoCount: Int; public var videoCount: Int }`
  - `public enum TakeoutPlanner { public static func plan(entries: [TakeoutSourceEntry], sidecars: [String: TakeoutSidecar] /* by "sourceId|path" */, albumTitles: [String: String] /* folder path → title */, allFilesAdded: Bool) -> TakeoutPlan }`

`fileWillTell` = no sidecar, but the extension is one that normally carries a capture date (HEIC, JPEG, DNG and other
RAW, MOV, MP4); the importer reads the date from the file and moves the item to `waiting` if it finds none.
`waiting` = no sidecar and no such date expected (PNG, GIF, WEBP, screenshots…) and `allFilesAdded == false`; with
`allFilesAdded == true` these become `fileWillTell` and the importer falls back to `entry.modified`.

- [ ] **Step 1: Write the failing tests**

```swift
func testYearAndAlbumCopiesBecomeOneItemWithAlbums()   // same name/size/crc in "Photos from 2019/" and "Goa 2019/" → 1 item, albums == ["Goa 2019"] (title from metadata.json)
func testLivePhotoPairsHEICAndMOV()                     // IMG_1.HEIC + IMG_1.MOV same folder → kind .livePhoto, pairedVideo set
func testMOVWithoutStillStaysVideo()                    // IMG_2.MOV alone → kind .video
func testEditedBecomesEditOfOriginal()                  // IMG_3.jpg + IMG_3-edited.jpg → one item, edited set
func testSidecarFromAnotherZipIsUsed()                  // photo in source A, sidecar in source B → sidecar attached, dateSource .google
func testPNGWithoutSidecarWaitsUntilAllFilesAdded()     // allFilesAdded false → .waiting; true → .fileWillTell
func testHEICWithoutSidecarLetsTheFileTell()            // → .fileWillTell
func testNonMediaIsSkippedAndCounted()                  // report.pdf → in skipped, not in items
func testItemKeyIsStableAcrossRuns()                    // same inputs in a different order → same keys
func testPixelMotionPairStaysTwoItems()                 // PXL_1.MP.jpg + PXL_1.MP.mp4 → one photo + one video, no pairedVideo
func testLateAlbumCopyOfImportedItem()                  // album copy whose key is already .done → reported in plan.lateDetails (key, albums, favorite)
func testLivePhotoHalfInAnotherSourceIsSeparate()       // HEIC in source A already .done, MOV arrives in source B → MOV is its own .video item
```

`TakeoutPlan` also gets `public var lateDetails: [(key: String, albums: [String], favorite: Bool)]` — album or
favourite information for items already imported, which Task 8 sends through `LibraryStore.queueMetaChanges`. The
planner takes `alreadyImportedKeys: Set<String>` as one more parameter.

- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** Year folders are recognised by the "contains a 4-digit year and has no `metadata.json`"
  rule rather than the English name; album names come only from folders with an album `metadata.json`.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit** — `import: turn a Takeout into photos, Live Photos and albums`

---

### Task 5: Local import table

**Files:**
- Modify: `Packages/LelvoCore/Sources/LelvoCore/Index/LibraryStore.swift` (append migration 6 → 7)
- Create: `Packages/LelvoCore/Sources/LelvoCore/Index/LibraryStore+Import.swift`
- Test: `Packages/LelvoCore/Tests/LelvoCoreTests/ImportStoreTests.swift`

Migration (local only, never uploaded):

```sql
CREATE TABLE IF NOT EXISTS import_sources (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL,
                                           bookmark BLOB NOT NULL, size INTEGER NOT NULL, added_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS import_items (key TEXT PRIMARY KEY, json TEXT NOT NULL, status TEXT NOT NULL,
                                         item_id TEXT, error TEXT, updated_at REAL NOT NULL);
```

**Interfaces:**
- Consumes: `TakeoutPlannedItem` (Task 4).
- Produces:
  - `public enum ImportStatus: String, Codable, Sendable { case pending, waitingForDetails, uploading, done, duplicate, skipped, failed }`
  - `public struct ImportSourceRecord: Codable, Sendable, Equatable { public var id: String; public var kind: String /* "zip" | "folder" */; public var name: String; public var bookmark: Data; public var size: Int64; public var addedAt: Date }`
  - `extension LibraryStore { func addImportSource(_:) throws; func importSources() throws -> [ImportSourceRecord]; func removeImportSource(id:) throws; func upsertPlanned(_ items: [TakeoutPlannedItem]) throws /* keeps status/item_id of existing keys */; func importItems(status: ImportStatus?) throws -> [(TakeoutPlannedItem, ImportStatus, String?)]; func setImportStatus(key:status:itemId:error:) throws; func importCounts() throws -> [ImportStatus: Int]; func isSourceFinished(id:) throws -> Bool; func clearImport() throws }`

- [ ] **Step 1: Write the failing tests**

```swift
func testMigrationCreatesImportTables()       // fresh store: user_version == 7; old v6 file migrates
func testUpsertKeepsProgress()                // set key "k" to .done with item id, upsert plan again → still .done, same item id
func testSourceFinishedOnlyWhenAllEntriesSettled() // one .pending entry from source A → false; all .done/.duplicate/.skipped → true
func testCounts()                             // 2 pending, 1 done → [.pending: 2, .done: 1]
```

- [ ] **Step 2–4:** fail, implement following the existing `trash_outbox` helpers' style, pass.
- [ ] **Step 5: Commit** — `import: remember Takeout progress in the local index`

---

### Task 6: Shared upload slot

**Files:**
- Modify: `Shared/Services/BackupEngine.swift` (add one internal method next to `withNoteSlot`; `process` unchanged)
- Modify: `Packages/LelvoCore/Sources/LelvoCore/Backup/UploadSlots.swift` only if a test shows the lane/note split
  needs a third kind; otherwise unchanged
- Test: `Packages/LelvoCore/Tests/LelvoCoreTests/BackupLogicTests.swift` (slot accounting)

**Interfaces:**
- Produces: `func withUploadSlot<T>(isCancelled: @escaping () -> Bool, _ body: () async throws -> T) async throws -> T`
  on `BackupEngine` — acquires a **lane** slot (`acquireLaneSlot`, no note priority), waits out `pausedUntil`, calls
  `paceUploadStart()`, runs `body`, releases; a `TDServiceError` `.floodWait(s)` extends `pausedUntil` (pausing backup
  too) and rethrows. Also `var isRunning: Bool` (read under `gate`) so the importer runs one lane while a backup run is
  active and two otherwise. Backup Pause and import Pause stay independent.

- [ ] **Step 1: Write the failing test** — `testLanesFromTwoOwnersNeverExceedTwo`: three `acquireForLane()` calls on one
  `UploadSlots(limit: 2)` → `true, true, false`; after `release()` → `true`. And in `TakeoutImportFlowTests` (Task 8):
  `TakeoutImportStep.laneCount(backupRunning: true) == 1`, `laneCount(backupRunning: false) == 2`.
- [ ] **Step 2–4:** run, implement `withUploadSlot`, run core tests and the iOS build.
- [ ] **Step 5: Commit** — `backup: let other uploads share the two upload slots`

---

### Task 7: Reading a file's own details

**Files:**
- Create: `Shared/Services/Import/ImportedFileInfo.swift`
- Create: `Packages/LelvoCore/Sources/LelvoCore/Import/ExifDate.swift`
- Test: `Packages/LelvoCore/Tests/LelvoCoreTests/ExifDateTests.swift`

**Interfaces:**
- Produces:
  - `public enum ExifDate { public static func parse(_ value: String, offset: String?) -> (date: Date, tzMinutes: Int?)? }`
  - `struct ImportedFileInfo { var width: Int; var height: Int; var duration: Double?; var codec: String?; var hdr: Int?; var takenAt: Date?; var tzMinutes: Int?; var latitude: Double?; var longitude: Double?; var thumbnailJPEG: Data?; static func read(_ url: URL, kind: MediaKind) async -> ImportedFileInfo }`

Images: ImageIO properties (`DateTimeOriginal`, `OffsetTimeOriginal`, GPS, pixel size with orientation) and
`CGImageSourceCreateThumbnailAtIndex` at 320 px, JPEG under 200 KB (same as backup thumbnails). Videos: `AVURLAsset`
creation date, duration, codec/HDR through the existing `VideoInfo` helpers if they accept a URL (add an `AVAsset`
overload if they don't), and a frame about 1 s in.

- [ ] **Step 1: Write the failing tests** — `"2019:07:04 18:22:01"` with `"+05:30"` → date `2019-07-04T12:52:01Z`,
  tz `330`; without offset → interpreted in UTC, tz `nil`; `"0000:00:00 00:00:00"` → `nil`.
- [ ] **Step 2–4:** fail, implement, pass; build iOS and Mac.
- [ ] **Step 5: Commit** — `import: read size, date and place from each imported file`

---

### Task 8: The importer

**Files:**
- Create: `Shared/Services/Import/TakeoutImporter.swift`
- Create: `Shared/Services/Import/ImportSource.swift` (zip or folder behind one protocol: `entries`, `extract`, `data`)
- Modify: `Shared/App/AppEnvironment.swift` (own one `TakeoutImporter`)
- Test: `Packages/LelvoCore/Tests/LelvoCoreTests/TakeoutImportFlowTests.swift` for the decision logic moved into core
  as `TakeoutImportStep.next(...)` (pure: given entry status, store lookups and free space → action)

**Interfaces:**
- Consumes: Tasks 1–7, `CloudUploader.upload(itemId:resource:encrypted:thumbnail:existing:resume:checkpoint:progress:)`,
  `LibraryStore.items(sha256:)`, `BackupEngine.withUploadSlot`, `BackupActivity` for progress.
- Produces:
  - `@MainActor final class TakeoutImporter: ObservableObject { @Published private(set) var state: State; @Published private(set) var counts: [ImportStatus: Int]; func add(urls: [URL]) async throws; func start(); func pause(); func allFilesAdded() async; func deleteSource(id: String) async throws; func clear() async }`
  - `enum State: Equatable { case idle, cataloguing, ready(neededBytes: Int64, freeBytes: Int64), importing, paused, needsSource(name: String), finished }`
  - `public enum TakeoutImportStep { public static func next(status: ImportStatus, existingBackedUpTwin: Bool, sourceAvailable: Bool, freeBytes: Int64, neededBytes: Int64) -> Action; public enum Action: Equatable { case upload, markDuplicate, waitForSource, stopForSpace(needed: Int64), skip } }`

Per item: `withUploadSlot` → space check → extract primary (and `pv`, `e`) to `staging/import-<key>/` → SHA-256 twin
in the store with status `.backedUp` → `.duplicate`, delete temp; otherwise `ImportedFileInfo.read`, choose date
(sidecar > file > `entry.modified` only after `allFilesAdded`), place (sidecar > file), build `MediaItem(localIdentifier:
nil, …)` with `albums`, `favorite`, `tzOffsetMinutes`, `hasEdit`; captions built the same way as
`BackupEngine.captionMeta` (move that function to an internal `CaptionMeta.make(for:role:hash:name:size:)` used by both,
no behaviour change); upload `o`, then `pv`, `e`, `t` (thumbnail, E2E), and `md` when albums don't fit; save the item
only after `isCompleteInCloud`; mark `.done` with the item id; delete the temp folder in `defer`. When
`ImportedFileInfo` has no thumbnail (the system can't decode the file), use a bundled placeholder JPEG (grey square
with `photo` or `video` symbol, rendered once at 320 px) so an encrypted item can still reach `backedUp`. Send
`plan.lateDetails` through `LibraryStore.queueMetaChanges` (adding albums and favourite, never removing). The same
applies to a `.duplicate` whose twin was backed up from the phone: add the Google item's albums and favourite to the
twin (owner's decision). Before each
upload, check the backup's Wi-Fi only rule (the same condition `BackupEngine.waitForConditions` uses) and show its
`StopReason.waitingForWiFi` text while waiting; Charging only is ignored. Run off the main actor;
publish to `MainActor`. Keep the screen awake on iOS while importing (`UIApplication.shared.isIdleTimerDisabled`), only
in the iOS target.

- [ ] **Step 1: Write the failing tests** for `TakeoutImportStep.next`:

```swift
next(status: .pending, existingBackedUpTwin: true,  sourceAvailable: true,  freeBytes: 10_000, neededBytes: 1) == .markDuplicate
next(status: .pending, existingBackedUpTwin: false, sourceAvailable: false, freeBytes: 10_000, neededBytes: 1) == .waitForSource
next(status: .pending, existingBackedUpTwin: false, sourceAvailable: true,  freeBytes: 100,    neededBytes: 500) == .stopForSpace(needed: 400)
next(status: .done,    existingBackedUpTwin: false, sourceAvailable: true,  freeBytes: 10_000, neededBytes: 1) == .skip
next(status: .uploading, existingBackedUpTwin: false, sourceAvailable: true, freeBytes: 10_000, neededBytes: 1) == .upload   // resume
```

- [ ] **Step 2–4:** fail, implement, pass; iOS and Mac builds clean (`Scripts/check-warnings.sh`).
- [ ] **Step 5: Manual check** on the simulator with a generated 50-photo Takeout zip (script in
  `Scripts/make-test-takeout.py`, photos with and without sidecars, one Live Photo, one album, one PDF, one sidecar in a
  second zip): counts match, dates and places right in the viewer, re-import → all `duplicate`.
- [ ] **Step 6: Commit** — `import: upload Takeout photos and videos straight to your Telegram library`

---

### Task 9: Screens

**Files:**
- Create: `Shared/Views/Backup/TakeoutGuideView.swift` (one view, `source: TakeoutSource` = `.photos` / `.drive`)
- Create: `Shared/Views/Backup/TakeoutImportView.swift`
- Create: `iOS/Views/Backup/TakeoutFilePicker.swift` (`UIDocumentPickerViewController`, types `.zip` + `.folder`,
  multiple, not as copy) and `macOS/Views/TakeoutFilePicker.swift` (`NSOpenPanel`)
- Modify: `Shared/Views/Backup/BackupDashboardView.swift` (Tools: two `NavigationLink`s after "Save all to Photos")
- Modify: `macOS/Views/MacBackupView.swift` (Tools: same two entries)
- Modify: `UITests/` — one test that opens each guide and checks the step texts exist (Debug launch argument
  `-uitestTakeoutFixture` loads a small bundled fixture plan instead of real files, `#if DEBUG` only)

Exact copy for the guide steps, footers and errors is in the spec's UI section; use it verbatim. Symbols:
`photo.stack` and `folder`. "Open Google Takeout" opens `https://takeout.google.com`.

- [ ] **Step 1:** Build the views; VoiceOver labels on every row with a value; Dynamic Type at the largest size doesn't
  clip.
- [ ] **Step 2:** iOS and Mac builds clean; screenshots of each screen in light and dark for the pull request.
- [ ] **Step 3:** `Scripts/build.sh uitest` passes.
- [ ] **Step 4: Commit** — `import: guide and import screens under Backup`

---

### Task 10: Finishing a zip, finishing the import, docs

**Files:**
- Modify: `Shared/Views/Backup/TakeoutImportView.swift`, `Shared/Services/Import/TakeoutImporter.swift`
- Modify: `docs/CHANGELOG.md`, `docs/FAQ.md` (switching from Google Photos), `docs/ARCHITECTURE.md` (Import section),
  `docs/PROGRESS.md`; `website/*.html` regenerated by the hook (`python3 Scripts/website-pages.py`)

- [ ] **Step 1:** Per-zip "Done" row with **Delete zip** (confirmation dialog: "Delete takeout-…-001.zip? Every photo
  and video in it is in your Telegram library." followed by the names of any entries in it that weren't imported —
  not a photo or video, or imported separately), shown only when `isSourceFinished(id:)`; deletes through the
  security-scoped URL; if the system refuses, say "Lelvo can't delete this file. Delete it in Files." **Add the next
  zip**. **That's all my files** → `allFilesAdded()`.
- [ ] **Step 2:** Results: lists for failed, imported without a date from Google, not imported (not a photo or video),
  each a plain `List` of names.
- [ ] **Step 3:** Docs updated; hook output checked.
- [ ] **Step 4:** `Scripts/build.sh test`, `ios`, `mac` all clean. Device check with a real Takeout (owner's choice of
  device; ask before running on their iPhone).
- [ ] **Step 5: Commit** — `import: finish a zip, finish the import, and document it`

---

### Task 11 (later phase): Android

Separate plan once Phase 1 ships: Kotlin `ZipArchive` over a seekable `ParcelFileDescriptor` + `Inflater` in
`android/core`, the matcher and planner ported with the **same test cases** as Tasks 2–4 and 7, the importer on the
Android `BackupEngine`'s slots, Storage Access Framework picker (files, SD card, USB), Compose screens under Backup.
