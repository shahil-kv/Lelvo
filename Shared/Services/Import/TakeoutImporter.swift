import Foundation
import SwiftUI
import UniformTypeIdentifiers
import LelvoCore
#if os(iOS)
import UIKit
#endif

/// Remembers "That's all my files" and how many entries weren't photos or videos. Neither is uploaded.
private enum TakeoutImportMemory {
    static let allFilesKey = "takeoutAllFilesAdded"
    static let notMediaKey = "takeoutNotMediaCount"

    static var allFilesAdded: Bool {
        get { UserDefaults.standard.bool(forKey: allFilesKey) }
        set { UserDefaults.standard.set(newValue, forKey: allFilesKey) }
    }

    static var notMedia: Int {
        get { UserDefaults.standard.integer(forKey: notMediaKey) }
        set { UserDefaults.standard.set(newValue, forKey: notMediaKey) }
    }
}

/// Pause, free-space and missing-zip signals shared by the import lanes. A new run gets a new epoch so a
/// finishing pass can't overwrite a newer one.
private final class ImportRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = 0
    private var paused = false
    private var spaceMessage: String?
    private var missingName: String?

    func beginRun() -> Int {
        lock.lock()
        defer { lock.unlock() }
        epoch += 1
        paused = false
        spaceMessage = nil
        missingName = nil
        return epoch
    }

    func pause() { lock.withLock { paused = true } }
    var isPaused: Bool { lock.withLock { paused } }
    var currentEpoch: Int { lock.withLock { epoch } }
    var stopMessage: String? { lock.withLock { spaceMessage } }
    var missingSource: String? { lock.withLock { missingName } }
    var blocked: Bool { lock.withLock { paused || spaceMessage != nil } }
    func allows(_ epoch: Int) -> Bool { lock.withLock { self.epoch == epoch && !paused } }

    func noteSpace(name: String, shortfall: Int64) {
        let bytes = ByteCountFormatter.string(fromByteCount: max(0, shortfall), countStyle: .file)
        let text = "There isn't enough space to import \(name). Free up \(bytes) or move the zip to a USB drive."
        lock.withLock { if spaceMessage == nil { spaceMessage = text } }
    }

    func noteMissing(_ name: String) {
        lock.withLock { if missingName == nil { missingName = name } }
    }
}

private actor ImportClaims {
    private var tried: Set<String> = []

    func claimNext(_ keys: [String]) -> String? {
        guard let key = keys.first(where: { !tried.contains($0) }) else { return nil }
        tried.insert(key)
        return key
    }
}

private final class OpenSources: @unchecked Sendable {
    let byID: [String: any ImportSource]
    init(_ sources: [any ImportSource]) {
        byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }
}

private struct CatalogOutcome: Sendable {
    var counts: [ImportStatus: Int]
    var skipped: Int
    var state: TakeoutImporter.State
    var message: String?
}

/// Uploads one Takeout entry at a time through the same lane slots, pacing and flood wait as backup.
@MainActor
final class TakeoutImporter: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case cataloguing
        case ready(neededBytes: Int64, freeBytes: Int64)
        case importing
        case paused
        case needsSource(name: String)
        case finished
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var counts: [ImportStatus: Int] = [:]
    /// Files that aren't photos or videos. They are counted and never uploaded.
    @Published private(set) var notMedia: Int = 0
    /// Why the import is waiting or stopped, in the same words backup uses for Wi-Fi.
    @Published private(set) var message: String?

    /// Shown before Start: largest file, one upload part, a margin, and the zip when it sits on this device.
    /// Nonisolated: the catalogue and the space estimate run off the main actor.
    nonisolated private static let readyMargin: Int64 = 300 << 20
    nonisolated private static let sidecarLimit: Int64 = 1 << 20

    nonisolated let env: AppEnvironment
    nonisolated private let control = ImportRunControl()
    private var runTask: Task<Void, Never>?

    /// Nonisolated so `AppEnvironment` can create it during launch. The type stays on the main actor after this returns.
    nonisolated init(environment: AppEnvironment) {
        env = environment
        // `notMedia` is main-actor state. `restore` publishes the saved count as soon as this returns.
        Task.detached { [weak self] in await self?.restore() }
    }

    func add(urls: [URL]) async throws {
        guard state != .importing else { throw ImportFailure("Pause the import before adding files.") }
        state = .cataloguing
        message = nil
        do {
            let store = env.store
            try await Task.detached { try Self.remember(urls, store: store) }.value
            try await rebuild(updateState: true)
        } catch {
            if state == .cataloguing { await settle() }
            throw error
        }
    }

    func start() {
        guard state != .importing, state != .cataloguing else { return }
        runTask?.cancel()
        let epoch = control.beginRun()
        state = .importing
        message = nil
        setAwake(true)
        clearLanes()
        runTask = Task.detached { [weak self] in
            await self?.perform(epoch: epoch)
            await self?.finish(epoch: epoch)
        }
    }

    func pause() {
        guard state == .importing || state == .cataloguing else { return }
        control.pause()
        runTask?.cancel()
        setAwake(false)
        clearLanes()
        state = .paused
        message = control.stopMessage
    }

    func allFilesAdded() async {
        TakeoutImportMemory.allFilesAdded = true
        let importing = state == .importing
        if !importing {
            state = .cataloguing
            message = nil
        }
        do {
            try await rebuild(updateState: !importing)
        } catch {
            if !importing, state == .cataloguing { await settle() }
        }
    }

    func deleteSource(id: String) async throws {
        guard state != .importing, state != .cataloguing else {
            throw ImportFailure("Pause the import before deleting a file.")
        }
        guard let record = try env.store.importSources().first(where: { $0.id == id }) else { return }
        if let url = OpenedImport.resolve(record.bookmark) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let path = url.path
            try await Task.detached {
                guard FileManager.default.fileExists(atPath: path) else { return }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw ImportFailure("Lelvo can't delete this file. Delete it in Files.")
                }
            }.value
        }
        try env.store.removeImportSource(id: id)
        try await rebuild(updateState: true)
    }

    func clear() async {
        runTask?.cancel()
        _ = control.beginRun()
        setAwake(false)
        clearLanes()
        TakeoutImportMemory.allFilesAdded = false
        TakeoutImportMemory.notMedia = 0
        try? env.store.clearImport()
        counts = [:]
        notMedia = 0
        message = nil
        state = .idle
    }

    // MARK: - Cataloguing

    /// The index, bookmarks and free-space check run off the main actor. Only the published state hops back.
    nonisolated private func restore() async {
        let snap = await Task.detached { self.snapshot() }.value
        let open = TakeoutImportStep.openCount(snap.counts)
        await MainActor.run {
            self.counts = snap.counts
            self.notMedia = snap.notMedia
            if snap.noRows {
                self.state = .idle
            } else if open == 0 {
                self.state = .finished
            } else {
                self.state = .ready(neededBytes: snap.needed, freeBytes: snap.free)
            }
        }
    }

    /// Groups every open zip and folder into items. Reading the zips and writing the index happen off the main actor.
    /// A zip that can't be opened is left as it was, so a missing file doesn't drop a sidecar or a Live Photo half.
    private func rebuild(updateState: Bool) async throws {
        let records = try env.store.importSources()
        let outcome = try await Task.detached { try self.writeCatalog(records) }.value
        TakeoutImportMemory.notMedia = outcome.skipped
        guard updateState, !control.isPaused else {
            counts = outcome.counts
            notMedia = outcome.skipped
            return
        }
        counts = outcome.counts
        notMedia = outcome.skipped
        state = outcome.state
        message = outcome.message
    }

    nonisolated private func writeCatalog(_ records: [ImportSourceRecord]) throws -> CatalogOutcome {
        var missing = Set<String>()
        var sources: [any ImportSource] = []
        for record in records {
            if let source = OpenedImport.open(record: record) { sources.append(source) }
            else { missing.insert(record.id) }
        }
        var entries: [TakeoutSourceEntry] = []
        var sidecars: [String: TakeoutSidecar] = [:]
        var albums: [String: String] = [:]
        for source in sources {
            for entry in try source.entries() {
                entries.append(TakeoutSourceEntry(sourceId: source.id, entry: entry))
                switch TakeoutMatcher.kind(ofPath: entry.path) {
                case .sidecar:
                    if let data = try? source.data(entry, limit: Self.sidecarLimit), let parsed = TakeoutSidecar.parse(data) {
                        sidecars[entry.path] = parsed
                    }
                case .albumMetadata:
                    if let data = try? source.data(entry, limit: Self.sidecarLimit), let meta = TakeoutAlbumMetadata.parse(data) {
                        albums[ImportPaths.directory(entry.path)] = meta.title
                    }
                default:
                    break
                }
            }
        }
        let previous = try env.store.importItems(status: nil)
        let previousByKey = Dictionary(previous.map { ($0.0.key, $0.0) }, uniquingKeysWith: { a, _ in a })
        var imported = Set<String>()
        for (item, status, itemId) in previous {
            switch status {
            case .done, .duplicate, .uploading: imported.insert(item.key)
            case .failed where itemId != nil: imported.insert(item.key)
            default: break
            }
        }
        let plan = TakeoutPlanner.plan(entries: entries, sidecars: sidecars, albumTitles: albums,
                                       allFilesAdded: TakeoutImportMemory.allFilesAdded, alreadyImportedKeys: imported)
        let saving = plan.items.compactMap { item -> TakeoutPlannedItem? in
            if let old = previousByKey[item.key], Self.touches(old, missing: missing) { return nil }
            guard !Self.touches(item, missing: missing) else { return nil }
            return Self.keepingEarlierDetails(item, previous: previousByKey[item.key])
        }
        if !saving.isEmpty { try env.store.upsertPlanned(saving) }
        let rows = try env.store.importItems(status: nil)
        for (item, status, itemId) in rows {
            if item.dateSource == .waiting, status == .pending || status == .failed {
                try env.store.setImportStatus(key: item.key, status: .waitingForDetails, itemId: itemId, error: nil)
            } else if item.dateSource != .waiting, status == .waitingForDetails {
                try env.store.setImportStatus(key: item.key, status: .pending, itemId: itemId, error: nil)
            }
        }
        try keepLateDetails(plan.lateDetails, previous: previous)
        let counts = try env.store.importCounts()
        let estimate = spaceEstimate()
        let left = TakeoutImportStep.openCount(counts)
        let state: State
        let message: String?
        if records.isEmpty && counts.isEmpty {
            state = .idle
            message = nil
        } else if left == 0 {
            state = .finished
            message = nil
        } else if missing.count == records.count, let name = records.first?.name {
            state = .needsSource(name: name)
            message = "\(name) is no longer where it was. Choose it again to continue."
        } else {
            state = .ready(neededBytes: estimate.needed, freeBytes: estimate.free)
            message = nil
        }
        return CatalogOutcome(counts: counts, skipped: plan.skipped.count, state: state, message: message)
    }

    nonisolated private static func touches(_ item: TakeoutPlannedItem, missing: Set<String>) -> Bool {
        if missing.contains(item.primary.sourceId) { return true }
        if let id = item.pairedVideo?.sourceId, missing.contains(id) { return true }
        if let id = item.edited?.sourceId, missing.contains(id) { return true }
        return item.copies.contains { missing.contains($0.sourceId) }
    }

    /// A zip that isn't here right now may still have supplied the date or the album last time. Don't drop those.
    nonisolated private static func keepingEarlierDetails(_ item: TakeoutPlannedItem, previous: TakeoutPlannedItem?) -> TakeoutPlannedItem {
        guard let previous else { return item }
        var item = item
        if item.sidecar == nil, let sidecar = previous.sidecar {
            item.sidecar = sidecar
            if sidecar.takenAt != nil { item.dateSource = .google }
        }
        if !previous.albums.isEmpty {
            item.albums = Array(Set(item.albums).union(previous.albums)).sorted()
        }
        return item
    }

    nonisolated private static func remember(_ urls: [URL], store: LibraryStore) throws {
        var seen = try store.importSources()
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let source = try OpenedImport.open(url: url, id: UUID().uuidString.lowercased())
            // Two copies of the same zip (same name and size) are one source. Folders can share a name.
            if source.kind == "zip", seen.contains(where: { $0.kind == "zip" && $0.name == source.name && $0.size == source.byteCount }) {
                continue
            }
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let record = ImportSourceRecord(id: source.id, kind: source.kind, name: source.name, bookmark: bookmark,
                                            size: source.byteCount, addedAt: Date())
            try store.addImportSource(record)
            seen.append(record)
        }
    }

    // MARK: - Uploading

    nonisolated private func perform(epoch: Int) async {
        guard await waitForNetwork(epoch: epoch) else { return }
        let records = (try? env.store.importSources()) ?? []
        let sources = OpenSources(records.compactMap { OpenedImport.open(record: $0) })
        let claims = ImportClaims()
        let pending = workKeys().count
        appLog("Import started: \(pending) to upload")
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !Task.isCancelled && control.allows(epoch) {
                let cap = control.blocked ? 0 : TakeoutImportStep.laneCount(backupRunning: env.engine.isRunning)
                if running < cap, let key = await claims.claimNext(workKeys()) {
                    let lane = running % 2
                    running += 1
                    group.addTask { [self] in
                        await self.process(key: key, lane: lane, epoch: epoch, sources: sources, records: records)
                    }
                    continue
                }
                if running == 0 { break }
                await group.next()
                running -= 1
            }
        }
    }

    nonisolated private func workKeys() -> [String] {
        let rows = (try? env.store.importItems(status: nil)) ?? []
        return rows.compactMap { item, status, _ -> (Int, String)? in
            switch status {
            case .uploading: return (0, item.key)
            case .pending: return (1, item.key)
            case .failed: return (2, item.key)
            default: return nil
            }
        }
        .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        .map(\.1)
    }

    nonisolated private func process(key: String, lane: Int, epoch: Int, sources: OpenSources, records: [ImportSourceRecord]) async {
        guard control.allows(epoch), !Task.isCancelled else { return }
        guard let row = ((try? env.store.importItems(status: nil)) ?? []).first(where: { $0.0.key == key }) else { return }
        let (planned, status, _) = row
        if planned.dateSource == .waiting, status != .uploading {
            try? env.store.setImportStatus(key: key, status: .waitingForDetails, itemId: row.2, error: nil)
            await publishCounts()
            return
        }
        let filename = ImportPaths.fileName(planned.primary.entry.path)
        let missing = Self.missingSource(for: planned, sources: sources, records: records)
        let free = CloudUploader.freeSpace(at: env.stagingDirectory) ?? Int64.max
        let needed = await bytesNeeded(planned)
        switch TakeoutImportStep.next(status: status, existingBackedUpTwin: false, sourceAvailable: missing == nil,
                                      freeBytes: free, neededBytes: needed) {
        case .skip:
            return
        case .waitForSource:
            control.noteMissing(missing ?? "A Takeout file")
            return
        case .stopForSpace(let short):
            control.noteSpace(name: filename, shortfall: short)
            return
        case .upload, .markDuplicate:
            break
        }
        guard await waitForNetwork(epoch: epoch) else { return }
        let laneKey = "import-\(lane)"
        await MainActor.run {
            BackupActivity.shared.lanes[laneKey] = BackupActivity.LaneProgress(name: filename, sent: 0, total: max(planned.primary.entry.size, 1))
        }
        defer {
            Task { @MainActor in BackupActivity.shared.lanes[laneKey] = nil }
        }
        var floods = 0
        while control.allows(epoch) && !Task.isCancelled {
            do {
                try await env.engine.withUploadSlot(isCancelled: { [control] in !control.allows(epoch) || Task.isCancelled }) {
                    try await self.send(key: key, laneKey: laneKey, epoch: epoch, sources: sources)
                }
                break
            } catch is CancellationError {
                return
            } catch {
                if let space = error as? NotEnoughSpaceError {
                    control.noteSpace(name: filename, shortfall: space.needed)
                    return
                }
                if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace {
                    control.noteSpace(name: filename, shortfall: needed)
                    return
                }
                if case .floodWait = (error.asTD as? TDServiceError)?.kind, floods < 6 {
                    floods += 1
                    continue
                }
                let itemId = ((try? env.store.importItems(status: nil)) ?? []).first { $0.0.key == key }?.2
                try? env.store.setImportStatus(key: key, status: .failed, itemId: itemId, error: error.localizedDescription)
                AppLog.shared.error("Import of \(filename) failed: \(error.localizedDescription)")
                break
            }
        }
        await publishCounts()
    }

    /// Extracts into `staging/import-<digest>/` and deletes that folder on every exit, including a throw.
    /// The digest stands in for the item key: the key contains `|` and the original file name.
    nonisolated private func send(key: String, laneKey: String, epoch: Int, sources: OpenSources) async throws {
        guard let row = ((try? env.store.importItems(status: nil)) ?? []).first(where: { $0.0.key == key }) else { return }
        let (planned, status, storedId) = row
        let filename = ImportPaths.fileName(planned.primary.entry.path)
        let needed = await bytesNeeded(planned)
        if let free = CloudUploader.freeSpace(at: env.stagingDirectory), free < needed {
            control.noteSpace(name: filename, shortfall: needed - free)
            return
        }
        let dir = workDirectory(key)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let primaryURL = dir.appendingPathComponent("o-" + filename.sanitizedFilename)
        let (primarySource, primaryEntry) = try resolved(planned.primary, sources: sources)
        let primaryHash = try primarySource.extract(primaryEntry, to: primaryURL)
        let primarySize = try CloudUploader.size(of: primaryURL)

        var pairedURL: URL?
        var pairedHash: String?
        if let paired = planned.pairedVideo {
            let url = dir.appendingPathComponent("pv-" + ImportPaths.fileName(paired.entry.path).sanitizedFilename)
            let (source, entry) = try resolved(paired, sources: sources)
            pairedHash = try source.extract(entry, to: url)
            pairedURL = url
        }
        var editedURL: URL?
        var editedHash: String?
        if let edited = planned.edited {
            let url = dir.appendingPathComponent("e-" + ImportPaths.fileName(edited.entry.path).sanitizedFilename)
            let (source, entry) = try resolved(edited, sources: sources)
            editedHash = try source.extract(entry, to: url)
            editedURL = url
        }

        let existing = storedId.flatMap { try? env.store.item(id: $0) }
        let twin = ((try? env.store.items(sha256: primaryHash)) ?? []).first { $0.status == .backedUp && $0.id != existing?.id }
        let hasParts = existing?.hasCloudParts == true
        // No confirmed part yet: a twin is a duplicate. Parts already in the channel keep going, so a resume isn't dropped.
        let afterHash = TakeoutImportStep.next(status: hasParts ? .uploading : .pending, existingBackedUpTwin: twin != nil,
                                               sourceAvailable: true, freeBytes: Int64.max, neededBytes: 0)
        if afterHash == .markDuplicate, let twin {
            if let existing, existing.id != twin.id, !hasParts { try? env.store.delete(id: existing.id) }
            try env.store.setImportStatus(key: key, status: .duplicate, itemId: twin.id, error: nil)
            addNotes(itemId: twin.id, albums: planned.albums, favorite: planned.sidecar?.favorite == true)
            appLog("\(filename) is already in the library (\(primarySize) bytes)")
            return
        }

        let info = await ImportedFileInfo.read(primaryURL, kind: planned.kind == .video ? .video : .photo)
        var videoInfo: ImportedFileInfo?
        if planned.kind == .livePhoto, let pairedURL {
            videoInfo = await ImportedFileInfo.read(pairedURL, kind: .video)
        }
        let fileDate = info.takenAt ?? videoInfo?.takenAt
        let fileZone = info.takenAt != nil ? info.tzMinutes : videoInfo?.tzMinutes
        let (date, zone): (Date?, Int?)
        if let taken = planned.sidecar?.takenAt {
            (date, zone) = (taken, nil)
        } else if let fileDate {
            (date, zone) = (fileDate, fileZone)
        } else if TakeoutImportMemory.allFilesAdded || status == .uploading {
            // The zip's own stamp, and only once the user has said every file is here (or this upload already started).
            (date, zone) = (planned.primary.entry.modified, nil)
        } else {
            try env.store.setImportStatus(key: key, status: .waitingForDetails, itemId: storedId, error: nil)
            return
        }

        let place = Self.place(sidecar: planned.sidecar, file: info)
        let id = existing?.id ?? storedId ?? UUID().uuidString.lowercased()
        var item = existing ?? MediaItem(id: id, localIdentifier: nil, sha256: primaryHash, filename: filename,
                                         kind: planned.kind, creationDate: date, latitude: place?.0, longitude: place?.1,
                                         pixelWidth: info.width, pixelHeight: info.height,
                                         duration: planned.kind == .video ? info.duration : videoInfo?.duration,
                                         fileSize: primarySize, encrypted: env.library.isEncrypted, status: .uploading)
        item.localIdentifier = nil
        item.sha256 = primaryHash
        item.filename = filename
        item.kind = planned.kind
        item.uti = UTType(filenameExtension: (filename as NSString).pathExtension)?.identifier
        item.creationDate = date
        item.latitude = place?.0
        item.longitude = place?.1
        item.pixelWidth = info.width
        item.pixelHeight = info.height
        item.duration = planned.kind == .video ? info.duration : (videoInfo?.duration ?? info.duration)
        item.fileSize = primarySize
        item.encrypted = env.library.isEncrypted
        item.status = .uploading
        item.mimeType = filename.mimeTypeForFilename
        item.codec = planned.kind == .video ? info.codec : (videoInfo?.codec ?? info.codec)
        item.hdr = planned.kind == .video ? info.hdr : (videoInfo?.hdr ?? info.hdr)
        item.tzOffsetMinutes = zone
        // A zip added while this file was extracting is already on the stored plan. Union, so nothing already
        // on the item is cleared. A confirmed part keeps the caption already in the channel (the lowest message
        // id), so the note is the additions from before this write. Queued before the save: the note is what a
        // later scan keeps.
        let recorded = storedPlan(key) ?? planned
        var mergedAlbums = item.albums
        var mergedFavorite = item.favorite
        let lateNotes = TakeoutLateNotes.merge(
            albums: &mergedAlbums, favorite: &mergedFavorite, plannedAlbums: recorded.albums,
            plannedFavorite: recorded.sidecar?.favorite == true, hasConfirmedPart: hasParts)
        item.albums = mergedAlbums
        item.favorite = mergedFavorite
        if !lateNotes.isEmpty, let chatId = MetaSync.shared.noteChatId {
            try? env.store.queueMetaChanges([item.id: lateNotes], chatId: chatId)
            MetaSync.shared.schedule()
        }
        item.hasEdit = planned.edited == nil ? nil : true
        item.pairedVideoFilename = planned.pairedVideo.map { ImportPaths.fileName($0.entry.path) }
        if let pairedURL { item.pairedVideoSize = try CloudUploader.size(of: pairedURL) }
        item.editedFilename = planned.edited.map { ImportPaths.fileName($0.entry.path) }
        if let editedURL { item.editedSize = try CloudUploader.size(of: editedURL) }
        item.extrasChecked = true
        var hashes = ["o": primaryHash]
        if let pairedHash { hashes["pv"] = pairedHash }
        if let editedHash { hashes["e"] = editedHash }
        item.roleHashes = hashes
        // Saved before the first part so a crash can resume the same item. It stays out of the timeline until
        // every required part is confirmed: the gallery only shows backed-up items.
        try env.store.upsert(item)
        try env.store.setImportStatus(key: key, status: .uploading, itemId: item.id, error: nil)

        let thumbData = info.thumbnailJPEG ?? ImportPlaceholder.jpeg(for: planned.kind)
        let thumbURL = dir.appendingPathComponent("thumb.jpg")
        try thumbData.write(to: thumbURL)
        var thumbSize = (320, 320)
        if let px = ImageDimensions.pixelSize(of: thumbData) { thumbSize = (px.width, px.height) }

        var original = CaptionMeta.make(for: item, role: .original, hash: primaryHash, name: filename, size: primarySize)
        var metadataFile: (url: URL, data: Data)?
        if try !CaptionCodec.keepsAlbums(original, captionKey: env.library.keys?.captionKey), let albums = original.a {
            let data = try ExtraMetadata(a: albums).encoded()
            let url = dir.appendingPathComponent("md.json")
            try data.write(to: url)
            metadataFile = (url, data)
            original.a = nil
        }
        var resources = [PreparedResource(role: "o", fileURL: primaryURL, meta: original)]
        if let pairedURL, let pairedHash {
            resources.append(PreparedResource(role: "pv", fileURL: pairedURL,
                                              meta: CaptionMeta.make(for: item, role: .pairedVideo, hash: pairedHash,
                                                                     name: item.pairedVideoFilename ?? "paired.mov",
                                                                     size: item.pairedVideoSize ?? 0)))
        }
        if let editedURL, let editedHash {
            resources.append(PreparedResource(role: "e", fileURL: editedURL,
                                              meta: CaptionMeta.make(for: item, role: .edited, hash: editedHash,
                                                                     name: item.editedFilename ?? "edited",
                                                                     size: item.editedSize ?? 0)))
        }
        if item.encrypted {
            resources.append(PreparedResource(role: "t", fileURL: thumbURL,
                                              meta: CaptionMeta.make(for: item, role: .thumbnail, hash: IndexCodec.sha256Hex(thumbData),
                                                                     name: "thumb.jpg", size: Int64(thumbData.count))))
        }
        if let metadataFile {
            resources.append(PreparedResource(role: "md", fileURL: metadataFile.url,
                                              meta: Self.metadataMeta(item, hash: IndexCodec.sha256Hex(metadataFile.data),
                                                                      size: Int64(metadataFile.data.count))))
        }

        let store = env.store
        let itemId = item.id
        let streamTotal = resources.reduce(Int64(0)) { $0 + ((try? CloudUploader.size(of: $1.fileURL)) ?? 0) }
        var sentBefore: Int64 = 0
        for resource in resources {
            try Task.checkCancellation()
            if !control.allows(epoch) { throw CancellationError() }
            let base = sentBefore
            let role = resource.role
            let parts = try await env.uploader.upload(
                itemId: itemId, resource: resource, encrypted: item.encrypted,
                thumbnail: (thumbURL, thumbSize.0, thumbSize.1),
                existing: item.parts(role), resume: item.uploadResume?[role],
                checkpoint: { parts, expected, resume in
                    try store.update(id: itemId) { $0.setParts(parts, role: role, expected: expected, resume: resume) }
                },
                progress: { sent, _ in
                    let name = filename
                    let total = streamTotal
                    Task { @MainActor in
                        BackupActivity.shared.lanes[laneKey] = BackupActivity.LaneProgress(name: name, sent: min(base + sent, total), total: total)
                    }
                })
            item = (try? store.item(id: itemId)) ?? item
            item.setParts(parts, role: role, expected: parts.count)
            if !["o", "pv", "e", "t"].contains(role) {
                item.roleNames = (item.roleNames ?? [:]).merging([role: resource.meta.n]) { $1 }
            }
            sentBefore += (try? CloudUploader.size(of: resource.fileURL)) ?? 0
        }

        item = (try? store.item(id: itemId)) ?? item
        var finalHashes = item.roleHashes ?? hashes
        finalHashes["o"] = primaryHash
        if let pairedHash { finalHashes["pv"] = pairedHash }
        if let editedHash { finalHashes["e"] = editedHash }
        for resource in resources where !["o", "pv", "e"].contains(resource.role) { finalHashes[resource.role] = resource.meta.h }
        item.roleHashes = finalHashes
        guard item.isCompleteInCloud else {
            item.status = .failed
            item.lastError = "This photo didn't finish uploading. It will be tried again."
            try store.upsert(item)
            try store.setImportStatus(key: key, status: .failed, itemId: item.id, error: item.lastError)
            return
        }
        item.status = .backedUp
        item.uploadedAt = Date()
        item.lastError = nil
        try store.upsert(item)
        try store.setImportStatus(key: key, status: .done, itemId: item.id, error: nil)
        // A zip that landed after the plan was copied above. Albums already on that plan, with a part confirmed,
        // were queued before the copy. This one is still missing from the item.
        if let recorded = storedPlan(key) {
            addNotes(itemId: item.id, albums: recorded.albums, favorite: recorded.sidecar?.favorite == true)
        }
        _ = try? env.thumbnailCache.store(data: thumbData, for: CloudMediaService.thumbnailKey(item), ext: "jpg")
        appLog("Imported \(filename) (\(primarySize) bytes)")
    }

    nonisolated private func resolved(_ stored: TakeoutSourceEntry, sources: OpenSources) throws -> (any ImportSource, ZipEntry) {
        guard let source = sources.byID[stored.sourceId] else {
            throw ImportFailure("A Takeout file is no longer where it was. Choose it again to continue.")
        }
        if source.kind == "folder" { return (source, stored.entry) }
        // A stored offset can point at a different file after the zip is rewritten. Match the entry again, or stop.
        guard let fresh = try source.entries().first(where: { $0.path == stored.entry.path && $0.size == stored.entry.size && $0.crc32 == stored.entry.crc32 }) else {
            throw ImportFailure("A file in the Takeout zip is no longer there. Choose the zip again to continue.")
        }
        return (source, fresh)
    }

    nonisolated private func bytesNeeded(_ item: TakeoutPlannedItem) async -> Int64 {
        let sizes = [item.primary.entry.size, item.pairedVideo?.entry.size, item.edited?.entry.size].compactMap { $0 }
        let limit = env.td.isReady ? await env.td.uploadLimit() : PartLayout.standardLimit
        return PartLayout.spaceNeeded(exportSizes: sizes, encrypted: env.library.isEncrypted, limit: limit) + CloudUploader.spaceMargin
    }

    nonisolated private func workDirectory(_ key: String) -> URL {
        let digest = String(IndexCodec.sha256Hex(Data(key.utf8)).prefix(16))
        return env.stagingDirectory.appendingPathComponent("import-\(digest)", isDirectory: true)
    }

    nonisolated private static func missingSource(for item: TakeoutPlannedItem, sources: OpenSources, records: [ImportSourceRecord]) -> String? {
        let ids = [item.primary.sourceId, item.pairedVideo?.sourceId, item.edited?.sourceId].compactMap { $0 }
        guard let missing = ids.first(where: { sources.byID[$0] == nil }) else { return nil }
        return records.first { $0.id == missing }?.name ?? "A Takeout file"
    }

    nonisolated private static func place(sidecar: TakeoutSidecar?, file: ImportedFileInfo) -> (Double, Double)? {
        if let lat = sidecar?.latitude, let lon = sidecar?.longitude { return (lat, lon) }
        if let lat = file.latitude, let lon = file.longitude { return (lat, lon) }
        return nil
    }

    nonisolated private static func metadataMeta(_ item: MediaItem, hash: String, size: Int64) -> CaptionMeta {
        var meta = CaptionMeta.make(for: item, role: .metadata, hash: hash, name: "metadata.json", size: size)
        meta.m = "application/json"
        meta.a = nil
        meta.wh = nil
        return meta
    }

    /// Albums and a favourite for an item that is already backed up or trashed. Queued as additions only, and
    /// written on the item here so this device shows them before the note comes back.
    nonisolated private func addNotes(itemId: String, albums: [String], favorite: Bool) {
        guard let item = try? env.store.item(id: itemId),
              item.status == .backedUp || item.status == .trashed else { return }
        let additions = TakeoutLateNotes.additions(existingAlbums: item.albums ?? [], existingFavorite: item.favorite == true,
                                                   albums: albums, favorite: favorite)
        guard !additions.isEmpty else { return }
        if let chatId = MetaSync.shared.noteChatId {
            try? env.store.queueMetaChanges([itemId: additions], chatId: chatId)
            MetaSync.shared.schedule()
        }
        _ = try? env.store.update(id: itemId) { MetaLog.apply(additions, to: &$0) }
    }

    /// A later zip's albums. An item already backed up (or trashed) gets a note. One still uploading or failed,
    /// and not backed up yet, keeps them on the stored plan. The next send writes them on the item, and queues
    /// the additions when a part is already confirmed, because that caption is not replaced.
    nonisolated private func keepLateDetails(_ details: [TakeoutLateDetail], previous: [(TakeoutPlannedItem, ImportStatus, String?)]) throws {
        guard !details.isEmpty else { return }
        let rows = Dictionary(previous.map { ($0.0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [TakeoutPlannedItem] = []
        for detail in details {
            guard let (planned, status, itemId) = rows[detail.key] else { continue }
            if let itemId, let library = try env.store.item(id: itemId),
               library.status == .backedUp || library.status == .trashed {
                addNotes(itemId: itemId, albums: detail.albums, favorite: detail.favorite)
                continue
            }
            guard status == .uploading || status == .failed else { continue }
            let next = planned.addingLateDetails(albums: detail.albums, favorite: detail.favorite)
            if next != planned { merged.append(next) }
        }
        if !merged.isEmpty { try env.store.upsertPlanned(merged) }
    }

    nonisolated private func storedPlan(_ key: String) -> TakeoutPlannedItem? {
        ((try? env.store.importItems(status: nil)) ?? []).first { $0.0.key == key }?.0
    }

    /// Wi-Fi only, same check as backup, without Charging only. Waits until the network is usable or the user pauses.
    nonisolated private func waitForNetwork(epoch: Int) async -> Bool {
        while control.allows(epoch), !Task.isCancelled {
            guard let reason = networkBlocker() else {
                await setMessage(nil)
                return true
            }
            if case .notConfigured = reason {
                control.pause()
                await setMessage(reason.localizedDescription)
                return false
            }
            await setMessage(reason.localizedDescription)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    nonisolated private func networkBlocker() -> BackupEngine.StopReason? {
        if !env.isConfigured { return .notConfigured }
        if !NetworkStatus.shared.isOnline { return .offline }
        if Prefs.wifiOnly && NetworkStatus.shared.isExpensive { return .waitingForWiFi }
        return nil
    }

    /// Counts, whether anything is stored, free space, and how many entries weren't photos or videos.
    /// Bookmarks and the volume check live in `spaceEstimate`. Call this off the main actor.
    nonisolated private func snapshot() -> (counts: [ImportStatus: Int], noRows: Bool, needed: Int64, free: Int64, notMedia: Int) {
        let counts = (try? env.store.importCounts()) ?? [:]
        let sources = (try? env.store.importSources()) ?? []
        let estimate = spaceEstimate()
        return (counts, sources.isEmpty && counts.isEmpty, estimate.needed, estimate.free, TakeoutImportMemory.notMedia)
    }

    nonisolated private func spaceEstimate() -> (needed: Int64, free: Int64) {
        let rows = (try? env.store.importItems(status: nil)) ?? []
        let work = rows.filter { [.pending, .uploading, .failed, .waitingForDetails].contains($0.1) }
        let largest = work.map { max($0.0.primary.entry.size, $0.0.pairedVideo?.entry.size ?? 0, $0.0.edited?.entry.size ?? 0) }.max() ?? 0
        var needed = largest + min(largest, PartLayout.standardLimit) + Self.readyMargin
        for record in (try? env.store.importSources()) ?? [] where record.kind == "zip" && Self.volumeIsInternal(record) {
            needed += record.size
        }
        return (needed, CloudUploader.freeSpace(at: env.stagingDirectory) ?? 0)
    }

    nonisolated private static func volumeIsInternal(_ record: ImportSourceRecord) -> Bool {
        guard let url = OpenedImport.resolve(record.bookmark) else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal == true
    }

    // MARK: - Publishing

    nonisolated private func finish(epoch: Int) async {
        guard control.currentEpoch == epoch else { return }
        await MainActor.run { self.setAwake(false); self.clearLanes() }
        guard control.currentEpoch == epoch else { return }
        if let text = control.stopMessage {
            await MainActor.run {
                guard self.control.currentEpoch == epoch else { return }
                self.state = .paused
                self.message = text
            }
            await publishCounts()
            appLog("Import stopped: not enough free space")
            return
        }
        if control.isPaused {
            await MainActor.run {
                guard self.control.currentEpoch == epoch else { return }
                self.state = .paused
            }
            await publishCounts()
            appLog("Import paused")
            return
        }
        await settle(epoch: epoch)
        let counts = (try? env.store.importCounts()) ?? [:]
        appLog("Import finished: \(counts[.done] ?? 0) imported, \(counts[.duplicate] ?? 0) already in the library, \(counts[.failed] ?? 0) failed")
    }

    /// Same reads as `restore`, off the main actor. Failed rows stay open so Start can retry them.
    nonisolated private func settle(epoch: Int? = nil) async {
        if let epoch, control.currentEpoch != epoch { return }
        let snap = await Task.detached { self.snapshot() }.value
        if let epoch, control.currentEpoch != epoch { return }
        let open = TakeoutImportStep.openCount(snap.counts)
        await MainActor.run {
            if let epoch, self.control.currentEpoch != epoch { return }
            self.counts = snap.counts
            if snap.noRows {
                self.state = .idle
                self.message = nil
            } else if let name = self.control.missingSource, open > 0 {
                self.state = .needsSource(name: name)
                self.message = "\(name) is no longer where it was. Choose it again to continue."
            } else if open == 0 {
                self.state = .finished
                self.message = nil
            } else {
                self.state = .ready(neededBytes: snap.needed, freeBytes: snap.free)
                self.message = nil
            }
        }
    }

    nonisolated private func publishCounts() async {
        let counts = (try? env.store.importCounts()) ?? [:]
        await MainActor.run { self.counts = counts }
    }

    nonisolated private func setMessage(_ text: String?) async {
        await MainActor.run { self.message = text }
    }

    private func setAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    private func clearLanes() {
        for key in BackupActivity.shared.lanes.keys where key.hasPrefix("import-") {
            BackupActivity.shared.lanes[key] = nil
        }
    }
}
