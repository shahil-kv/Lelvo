import Foundation
import Photos
import UIKit
import Network
import CloudGalleryCore

/// Live state for the UI (Backup tab, progress bars).
@MainActor
final class BackupActivity: ObservableObject {
    static let shared = BackupActivity()
    @Published var isRunning = false
    @Published var done = 0
    @Published var total = 0
    /// Per upload lane: the file being uploaded and its byte progress (two uploads run in parallel).
    @Published var lanes: [String: LaneProgress] = [:]
    @Published var uploaded = 0
    @Published var failed = 0
    @Published var message: String?
    /// Temporary notice while Telegram's requested pause is in effect; cleared when it ends.
    @Published var notice: String?

    struct LaneProgress: Equatable {
        var name: String
        var sent: Int64
        var total: Int64
    }

    /// Items not yet handled in the current run.
    var remaining: Int { max(0, total - done) }
    @Published var lastSummary: BackupEngine.Summary?
}

/// Current network path (for Wi-Fi only).
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            self.lock.withLock { self.path = p }
        }
        monitor.start(queue: DispatchQueue(label: "cloudgallery.network"))
    }

    /// Unknown counts as online so the first run isn't blocked before the monitor reports.
    var isOnline: Bool { lock.withLock { path.map { $0.status == .satisfied } ?? true } }
    /// Cellular, personal hotspot or Low Data Mode.
    var isExpensive: Bool { lock.withLock { (path?.isExpensive ?? false) || (path?.isConstrained ?? false) } }
}

/// Runs the persistent upload queue: pending → uploading → verified | failed(reason).
/// An item is verified only after Telegram confirms every part and the stored sizes match.
final class BackupEngine: @unchecked Sendable {
    struct Summary: Equatable {
        var uploaded = 0
        var alreadyBackedUp = 0
        var failed = 0
        var remaining = 0
        var error: String?

        var text: String {
            if let error { return error }
            var parts = ["Backed up \(uploaded) item\(uploaded == 1 ? "" : "s")"]
            if alreadyBackedUp > 0 { parts.append("\(alreadyBackedUp) already in the cloud") }
            if failed > 0 { parts.append("\(failed) failed") }
            if remaining > 0 { parts.append("\(remaining) still waiting") }
            return parts.joined(separator: ", ") + "."
        }
    }

    enum StopReason: LocalizedError {
        case notConfigured, noPhotoAccess, waitingForWiFi, waitingForPower, offline, alreadyRunning
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "CloudGallery isn't set up yet. Open the app to sign in to Telegram."
            case .noPhotoAccess: return "CloudGallery has no access to your photos."
            case .waitingForWiFi: return "Waiting for Wi-Fi (Wi-Fi only is on)."
            case .waitingForPower: return "Waiting for the charger (Charging only is on)."
            case .offline: return "No internet connection."
            case .alreadyRunning: return "A backup is already running."
            }
        }
    }

    enum Outcome { case uploaded, duplicate, failed, skipped, retryLater }

    /// Minimum gap between starting uploads (across both lanes), so Telegram rarely has to say "slow down".
    static let uploadSpacing: TimeInterval = 1.5
    private var nextUploadStart = Date.distantPast

    private func paceUploadStart() async {
        let wait: TimeInterval = gate.withLock {
            let slot = max(Date(), nextUploadStart)
            nextUploadStart = slot.addingTimeInterval(Self.uploadSpacing)
            return slot.timeIntervalSinceNow
        }
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    static let maxConcurrentUploads = 2

    private unowned let env: AppEnvironment
    private let gate = NSLock()
    private var running = false
    private var pausedUntil = Date.distantPast
    private var pauseRequested = false
    private var laneTask: Task<Void, Never>?
    private var isPauseRequested: Bool { gate.withLock { pauseRequested } }

    /// Stops the running backup immediately (in-flight uploads are cancelled and go back to the queue)
    /// and keeps it paused for automatic runs until the user taps Back up now.
    func pause() {
        Prefs.backupPaused = true
        let task: Task<Void, Never>? = gate.withLock {
            pauseRequested = true
            return laneTask
        }
        task?.cancel()
        appLog("Backup paused by the user")
    }

    init(environment: AppEnvironment) {
        self.env = environment
    }

    private var rawDirectory: URL {
        let dir = env.stagingDirectory.appendingPathComponent("raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private func publish(_ change: @MainActor (BackupActivity) -> Void) { change(BackupActivity.shared) }

    var isRunning: Bool { gate.withLock { running } }

    /// Why the queue can't run right now (nil = OK).
    @MainActor func blocker() -> StopReason? {
        if !env.isConfigured { return .notConfigured }
        if !PhotoLibraryService.hasAccess { return .noPhotoAccess }
        if !NetworkStatus.shared.isOnline { return .offline }
        if Prefs.wifiOnly && NetworkStatus.shared.isExpensive { return .waitingForWiFi }
        if Prefs.chargingOnly {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            if state != .charging && state != .full { return .waitingForPower }
        }
        return nil
    }

    // MARK: - Queue

    /// Adds phone assets that match the backup selection and aren't known yet as pending jobs.
    @discardableResult
    func enqueueNewAssets(force: Bool = false) -> Int {
        guard force || Prefs.autoBackup else { return 0 }
        let known = (try? env.store.knownLocalIdentifiers()) ?? []
        let fresh = env.photos.backupCandidates().filter { !known.contains($0.localIdentifier) }
        let items = fresh.map(makeItem)
        try? env.store.upsert(items)
        return items.count
    }

    /// After a reinstall the restored cloud items aren't linked to this iPhone's photos (the link lived only in
    /// the local database), so every photo looked "not backed up" and would be hashed again. Re-links them with
    /// `RestoreLinker` (caption asset id, else filename + capture second + pixel size) and drops queued
    /// duplicates of the linked photos. Returns the number of items linked.
    @discardableResult
    func relinkRestoredItems() -> Int {
        guard PhotoLibraryService.hasAccess else { return 0 }
        let all = (try? env.store.allItems()) ?? []
        let unlinked = all.filter { $0.status == .backedUp && $0.localIdentifier == nil }
        guard !unlinked.isEmpty else { return 0 }
        let linked = Set(all.filter { $0.status == .backedUp }.compactMap(\.localIdentifier))
        var assets: [AssetKey] = []
        env.photos.fetchAllAssets().enumerateObjects { asset, _, _ in
            guard !linked.contains(asset.localIdentifier),
                  let name = self.env.photos.originalResources(for: asset)?.primary.originalFilename else { return }
            assets.append(AssetKey(localIdentifier: asset.localIdentifier, filename: name, creationDate: asset.creationDate,
                                   pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight))
        }
        let links = RestoreLinker.match(unlinked: unlinked, assets: assets)
        guard !links.isEmpty else { return 0 }
        let linkedAssets = Set(links.values)
        let duplicates = all.filter { $0.status != .backedUp && $0.status != .uploading && $0.localIdentifier.map(linkedAssets.contains) == true }
        for d in duplicates { try? env.store.delete(id: d.id) }
        try? env.store.upsert(unlinked.compactMap { item in
            links[item.id].map { var i = item; i.localIdentifier = $0; return i }
        })
        appLog("Relinked \(links.count) of \(unlinked.count) restored items to photos on this iPhone (\(duplicates.count) queued duplicates removed)")
        return links.count
    }

    /// "Back up" on chosen photos: queues them regardless of the backup selection (and retries failed ones).
    @discardableResult
    func enqueue(localIdentifiers: [String]) -> Int {
        var items: [MediaItem] = []
        for id in localIdentifiers {
            if var existing = try? env.store.item(localIdentifier: id) {
                guard existing.status != .backedUp else { continue }
                if existing.status == .failed { existing.job = JobMachine.reduce(existing.job, .retry) }
                existing.chosen = true
                items.append(existing)
            } else if let asset = env.photos.asset(localIdentifier: id) {
                var item = makeItem(asset)
                item.chosen = true
                items.append(item)
            }
        }
        try? env.store.upsert(items)
        return items.count
    }

    private func makeItem(_ asset: PHAsset) -> MediaItem {
        let name = env.photos.originalResources(for: asset)?.primary.originalFilename ?? "IMG_\(asset.localIdentifier.prefix(8))"
        var item = MediaItem(localIdentifier: asset.localIdentifier, sha256: "", filename: name,
                             kind: PhotoLibraryService.kind(of: asset), creationDate: asset.creationDate,
                             latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
                             pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                             duration: asset.mediaType == .video ? asset.duration : nil, fileSize: 0,
                             encrypted: env.library.isEncrypted, status: .queued)
        item.favorite = asset.isFavorite ? true : nil
        return item
    }

    /// `onlyChosen`: just the items the user picked (see `MediaItem.chosen`).
    func runnableItems(now: Date, onlyChosen: Bool = false) -> [MediaItem] {
        let pending = ((try? env.store.items(status: .queued)) ?? []) + ((try? env.store.items(status: .uploading)) ?? [])
        return pending.filter { $0.localIdentifier != nil && ($0.notBefore.map { $0 <= now } ?? true) && (!onlyChosen || $0.chosen == true) }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    /// Processes the queue with up to two concurrent uploads until it is empty, `deadline` passes,
    /// or `isCancelled` returns true. Safe to call from the UI, App Intents and BGTasks.
    /// `includeNew`: also queue every photo not yet in the cloud ("Back up now"). Otherwise only items already
    /// queued (photos the user chose, retries) are uploaded, unless automatic backup is on.
    func run(deadline: Date? = nil, userStarted: Bool = false, includeNew: Bool = false,
             isCancelled callerCancelled: @escaping @Sendable () -> Bool = { false },
             progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Summary {
        var summary = Summary()
        if userStarted {
            Prefs.backupPaused = false
        } else if Prefs.backupPaused {
            summary.error = "Backup is paused. Open CloudGallery and tap Back up now to resume."
            return summary
        }
        if let reason = await blocker() { summary.error = reason.localizedDescription; return summary }
        let alreadyRunning: Bool = gate.withLock {
            if running { return true }
            running = true
            return false
        }
        if alreadyRunning { summary.error = StopReason.alreadyRunning.localizedDescription; return summary }
        defer { gate.withLock { running = false; laneTask = nil } }
        let isCancelled: @Sendable () -> Bool = { [weak self] in callerCancelled() || (self?.isPauseRequested ?? false) }
        gate.withLock { pauseRequested = false }

        await publish { $0.isRunning = true; $0.message = "Connecting to Telegram…" }
        do {
            try await env.td.waitUntilReady(timeout: 25)
        } catch {
            summary.error = error.localizedDescription
            await publish { $0.isRunning = false; $0.message = summary.error }
            return summary
        }
        // Reconcile anything sent before an interruption so it isn't uploaded twice.
        _ = try? await env.library.scan(full: false)
        relinkRestoredItems()
        enqueueNewAssets(force: includeNew)

        // Items left "uploading" by a killed process go back to pending.
        if let stale = try? env.store.items(status: .uploading) {
            try? env.store.upsert(stale.map { var i = $0; i.job = JobMachine.reduce(i.job, .interrupted); return i })
        }

        let onlyChosen = !includeNew && !Prefs.autoBackup
        let queue = JobQueue(items: runnableItems(now: Date(), onlyChosen: onlyChosen))
        let total = await queue.count
        await publish { a in
            a.done = 0
            a.total = total
            a.message = total == 0 ? "Everything is backed up." : "Backing up \(total) items…"
            a.lanes = [:]
            a.uploaded = 0
            a.failed = 0
        }
        appLog("Backup run: \(total) items queued")

        let counter = Counter()
        let lanes = Task { await withTaskGroup(of: Void.self) { group in
            for lane in 0..<Self.maxConcurrentUploads {
                group.addTask { [self] in
                    while let item = await queue.next() {
                        if isCancelled() || deadline.map({ Date() > $0 }) == true { await queue.drain(); break }
                        if let reason = await blocker() {
                            await publish { $0.message = reason.localizedDescription }
                            await queue.drain()
                            break
                        }
                        await waitForFloodPause(isCancelled: isCancelled)
                        await paceUploadStart()
                        let outcome = await process(item, lane: lane, isCancelled: isCancelled)
                        if outcome == .retryLater, await queue.requeue(item) {
                            // Slowed down or a temporary network error: try again later in this same run.
                            continue
                        }
                        let done = await counter.record(outcome)
                        let snap = await counter.snapshot()
                        progress?(done, total)
                        await publish { a in a.done = done; a.uploaded = snap.uploaded + snap.duplicate; a.failed = snap.failed }
                    }
                }
            }
        } }
        gate.withLock { laneTask = lanes }
        if isPauseRequested { lanes.cancel() }
        await lanes.value

        let counts = await counter.snapshot()
        summary.uploaded = counts.uploaded
        summary.alreadyBackedUp = counts.duplicate
        summary.failed = counts.failed
        summary.remaining = runnableItems(now: .distantFuture, onlyChosen: onlyChosen).count
        await env.enforceCacheLimits()
        if summary.uploaded > 0 { UserDefaults.standard.set(Date(), forKey: Prefs.Key.lastBackupAt) }
        if isPauseRequested {
            summary.error = "Paused. \(summary.uploaded) backed up in this run; tap Back up now to continue where it stopped."
        }
        let final = summary
        await publish { a in a.isRunning = false; a.lastSummary = final; a.message = final.text; a.lanes = [:]; a.notice = nil }
        appLog("Backup run finished: \(summary.text)")
        return summary
    }

    /// Moves every failed item back to pending (the "Retry failed" button).
    func retryFailed() {
        guard let failed = try? env.store.items(status: .failed) else { return }
        // Retrying is an explicit choice: these upload even when the rest of the queue is left alone.
        try? env.store.upsert(failed.map { var i = $0; i.job = JobMachine.reduce(i.job, .retry); i.chosen = true; return i })
    }

    private func waitForFloodPause(isCancelled: () -> Bool) async {
        var paused = false
        while !isCancelled() {
            let wait = gate.withLock { pausedUntil }.timeIntervalSinceNow
            if wait <= 0 { break }
            paused = true
            let seconds = Int(wait.rounded(.up))
            await publish { $0.notice = "Telegram asked to slow down: resuming in \(seconds) s." }
            try? await Task.sleep(nanoseconds: UInt64(min(wait, 1) * 1_000_000_000))
        }
        if paused { await publish { $0.notice = nil } }
    }

    // MARK: - One item

    private func save(_ item: MediaItem) { try? env.store.upsert(item) }

    private func process(_ queued: MediaItem, lane: Int, isCancelled: @escaping @Sendable () -> Bool) async -> Outcome {
        guard var item = try? env.store.item(id: queued.id), item.status == .queued || item.status == .uploading else { return .skipped }
        guard let localId = item.localIdentifier, let asset = env.photos.asset(localIdentifier: localId) else {
            // Deleted from the phone before it was uploaded: nothing left to back up.
            try? env.store.delete(id: item.id)
            return .skipped
        }
        item.job = JobMachine.reduce(item.job, .start)
        save(item)
        let laneKey = "\(lane)"
        let displayName = item.filename
        await publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: displayName, sent: 0, total: 0) }

        var exported: ExportedAsset?
        defer {
            exported?.cleanup()
            Task { await self.publish { $0.lanes[laneKey] = nil } }
        }
        do {
            let exp = try await env.photos.exportOriginal(of: asset, into: rawDirectory)
            exported = exp

            // Content hash and de-duplication against everything already in the cloud.
            let primaryHash = try Deduplicator.sha256(of: exp.primaryURL)
            let pairedHash = try exp.pairedVideoURL.map { try Deduplicator.sha256(of: $0) }
            if item.cloudParts == nil,
               let twin = try env.store.items(sha256: primaryHash).first(where: { $0.id != item.id && $0.status == .backedUp }) {
                let missing = twin.localIdentifier.map { env.photos.asset(localIdentifier: $0) == nil } ?? true
                try env.store.delete(id: item.id)
                try Deduplicator(store: env.store).link(localIdentifier: localId, to: twin, existingAssetIsMissing: missing)
                return .duplicate
            }
            item.sha256 = primaryHash
            item.filename = exp.primaryFilename
            item.kind = exp.kind
            item.uti = exp.primaryUTI
            item.fileSize = try CloudUploader.size(of: exp.primaryURL)
            item.pairedVideoFilename = exp.pairedVideoFilename
            item.pairedVideoSize = try exp.pairedVideoURL.map { try CloudUploader.size(of: $0) }
            let editedHash = try exp.editedURL.map { try Deduplicator.sha256(of: $0) }
            item.hasEdit = exp.editedURL != nil ? true : nil
            item.editedFilename = exp.editedFilename
            item.editedSize = try exp.editedURL.map { try CloudUploader.size(of: $0) }
            item.encrypted = env.library.isEncrypted
            item.mimeType = exp.primaryFilename.mimeTypeForFilename
            if let video = await VideoInfo.inspect(asset: asset) {
                item.codec = video.codec
                item.hdr = video.hdr
            }
            item.tzOffsetMinutes = TimeZone.current.secondsFromGMT(for: asset.creationDate ?? Date()) / 60
            item.albums = env.photos.albumNames(for: asset)
            save(item)

            // Thumbnail: attached to the document (plain) or uploaded encrypted as role "t" (E2E).
            let thumbData = await env.photos.thumbnailJPEG(for: asset)
            let thumbURL = rawDirectory.appendingPathComponent("\(item.id)-thumb.jpg")
            var thumbSize = (320, 320)
            if let thumbData {
                try thumbData.write(to: thumbURL)
                if let img = UIImage(data: thumbData) { thumbSize = (Int(img.size.width * img.scale), Int(img.size.height * img.scale)) }
                _ = try? env.thumbnailCache.store(data: thumbData, for: CloudMediaService.thumbnailKey(item), ext: "jpg")
            }
            defer { try? FileManager.default.removeItem(at: thumbURL) }

            var resources = [PreparedResource(role: "o", fileURL: exp.primaryURL,
                                              meta: captionMeta(item, role: .original, hash: primaryHash, name: item.filename, size: item.fileSize))]
            if let paired = exp.pairedVideoURL, let pairedHash {
                resources.append(PreparedResource(role: "pv", fileURL: paired,
                                                  meta: captionMeta(item, role: .pairedVideo, hash: pairedHash,
                                                                    name: item.pairedVideoFilename ?? "\(item.id).MOV", size: item.pairedVideoSize ?? 0)))
            }
            if let edited = exp.editedURL, let editedHash {
                resources.append(PreparedResource(role: "e", fileURL: edited,
                                                  meta: captionMeta(item, role: .edited, hash: editedHash,
                                                                    name: item.editedFilename ?? "edited", size: item.editedSize ?? 0)))
            }
            if item.encrypted, let thumbData {
                resources.append(PreparedResource(role: "t", fileURL: thumbURL,
                                                  meta: captionMeta(item, role: .thumbnail, hash: IndexCodec.sha256Hex(thumbData),
                                                                    name: "thumb.jpg", size: Int64(thumbData.count))))
            }

            let streamTotal = resources.reduce(Int64(0)) { $0 + ((try? CloudUploader.size(of: $1.fileURL)) ?? 0) }
            var sentBefore: Int64 = 0
            let store = env.store
            let itemId = item.id
            for resource in resources {
                try Task.checkCancellation()
                if isCancelled() { throw CancellationError() }
                let base = sentBefore
                let parts = try await env.uploader.upload(
                    itemId: itemId, resource: resource, encrypted: item.encrypted,
                    thumbnail: thumbData != nil ? (thumbURL, thumbSize.0, thumbSize.1) : nil,
                    existing: item.parts(resource.role),
                    checkpoint: { parts, expected in
                        try store.update(id: itemId) { $0.setParts(parts, role: resource.role, expected: expected) }
                    },
                    progress: { [weak self] sent, _ in
                        let name = item.filename
                        Task { await self?.publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: name, sent: min(base + sent, streamTotal), total: streamTotal) } }
                    })
                item = (try store.item(id: itemId)) ?? item
                item.setParts(parts, role: resource.role, expected: parts.count)
                sentBefore += (try? CloudUploader.size(of: resource.fileURL)) ?? 0
            }

            item.job = JobMachine.reduce(item.job, .sent(sizeMatches: item.isCompleteInCloud))
            item.uploadedAt = Date()
            var hashes = ["o": primaryHash]
            if let pairedHash { hashes["pv"] = pairedHash }
            if let editedHash { hashes["e"] = editedHash }
            item.roleHashes = hashes
            save(item)
            return item.status == .backedUp ? .uploaded : .failed
        } catch {
            return fail(&item, error)
        }
    }

    private func fail(_ item: inout MediaItem, _ error: Error) -> Outcome {
        let cancelled: Bool
        if error is CancellationError { cancelled = true }
        else if case TDServiceError.cancelled? = error as? TDServiceError { cancelled = true }
        else { cancelled = false }
        if cancelled {
            item.job = JobMachine.reduce(item.job, .interrupted)
            save(item)
            return .skipped
        }
        let kind: TelegramErrorKind
        if let td = error as? TDServiceError { kind = td.kind }
        else if error is CryptoError || error is PhotoLibraryError || error is LibraryError { kind = .permanent }
        else { kind = .transient }
        switch kind {
        case .floodWait(let s):
            gate.withLock { pausedUntil = max(pausedUntil, Date().addingTimeInterval(TimeInterval(s))) }
            item.job = JobMachine.reduce(item.job, .floodWait(seconds: s))
        case .transient:
            item.job = JobMachine.reduce(item.job, .error(reason: error.localizedDescription, transient: true))
        case .auth, .permanent:
            item.job = JobMachine.reduce(item.job, .error(reason: error.localizedDescription, transient: false))
        }
        save(item)
        if item.status == .failed {
            AppLog.shared.error("Upload of \(item.filename) failed: \(error.localizedDescription)")
            return .failed
        }
        appLog("Upload of \(item.filename) will be retried: \(error.localizedDescription)")
        return .retryLater
    }

    private func captionMeta(_ item: MediaItem, role: CaptionMeta.Role, hash: String, name: String, size: Int64) -> CaptionMeta {
        let kind: CaptionMeta.Kind = item.kind == .livePhoto ? .live : (item.kind == .video ? .video : .photo)
        var m = CaptionMeta(id: item.id, role: role, kind: kind, sha256: hash, name: name, size: size)
        m.m = name.mimeTypeForFilename
        m.t = item.creationDate.map { Int64($0.timeIntervalSince1970) }
        m.tz = item.tzOffsetMinutes
        if let lat = item.latitude, let lon = item.longitude { m.g = CaptionMeta.roundedGPS(lat, lon) }
        if item.pixelWidth > 0 { m.wh = [item.pixelWidth, item.pixelHeight] }
        m.d = role == .thumbnail ? nil : item.duration
        m.c = item.codec
        m.hdr = item.hdr
        m.a = item.albums
        m.fav = item.favorite == true ? 1 : nil
        m.l = item.localIdentifier
        m.ed = (role == .original && item.hasEdit == true) ? 1 : nil
        return m
    }
}

/// Hands out queue items to the upload lanes, one at a time.
actor JobQueue {
    private var items: [MediaItem]
    init(items: [MediaItem]) { self.items = items.reversed() }
    var count: Int { items.count }
    private var requeues: [String: Int] = [:]
    func next() -> MediaItem? { items.popLast() }
    func drain() { items.removeAll() }

    /// Puts an item back at the end of the queue (at most 5 times per run). Returns false when exhausted.
    func requeue(_ item: MediaItem) -> Bool {
        let n = requeues[item.id, default: 0]
        guard n < 5 else { return false }
        requeues[item.id] = n + 1
        items.insert(item, at: 0)
        return true
    }
}

actor Counter {
    private var uploaded = 0, duplicate = 0, failed = 0, done = 0
    func record(_ o: BackupEngine.Outcome) -> Int {
        switch o {
        case .uploaded: uploaded += 1
        case .duplicate: duplicate += 1
        case .failed: failed += 1
        case .skipped, .retryLater: break
        }
        done += 1
        return done
    }
    func snapshot() -> (uploaded: Int, duplicate: Int, failed: Int) { (uploaded, duplicate, failed) }
}
