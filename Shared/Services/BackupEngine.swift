import Foundation
import Photos
import AVFoundation
import Network
import MemvoCore

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

/// Current network path (for Wi-Fi only, video quality, and telling TDLib when the network changes).
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    private var lastKind: Kind?

    enum Kind: String { case wifi = "Wi-Fi", mobile = "mobile data", other = "other network", none = "no network" }

    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            let kind = Self.kind(of: p)
            let changed: Bool = self.lock.withLock {
                self.path = p
                defer { self.lastKind = kind }
                return self.lastKind != nil && self.lastKind != kind
            }
            if changed {
                appLog("Network changed to \(kind.rawValue)")
                TDService.shared.networkChanged(to: kind)
            }
        }
        monitor.start(queue: DispatchQueue(label: "memvo.network"))
    }

    var kind: Kind { lock.withLock { path.map(Self.kind(of:)) ?? .other } }

    private static func kind(of p: NWPath) -> Kind {
        guard p.status == .satisfied else { return .none }
        if p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet) { return .wifi }
        if p.usesInterfaceType(.cellular) { return .mobile }
        return .other
    }

    /// Unknown counts as online so the first run isn't blocked before the monitor reports.
    var isOnline: Bool { lock.withLock { path.map { $0.status == .satisfied } ?? true } }
    /// Cellular, personal hotspot or Low Data Mode.
    var isExpensive: Bool { lock.withLock { (path?.isExpensive ?? false) || (path?.isConstrained ?? false) } }

    /// Why the network counts as expensive, for the log ("Wi-Fi only" waits while on Wi-Fi need explaining).
    var expenseDetail: String {
        lock.withLock {
            guard let p = path else { return "network unknown" }
            var parts = [Self.kind(of: p).rawValue]
            if p.isExpensive { parts.append("expensive (cellular or hotspot)") }
            if p.isConstrained { parts.append("Low Data Mode") }
            return parts.joined(separator: ", ")
        }
    }
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
            case .notConfigured: return "Memvo isn't set up yet. Open the app to sign in to Telegram."
            case .noPhotoAccess: return "Memvo has no access to your photos."
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
    private let relinkLock = NSLock()
    private var running = false
    private var pausedUntil = Date.distantPast
    /// Upload lanes currently waiting in `waitForConditions`.
    private var waitingLanes = 0
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
        // Only logged before, so a throttled upload looked stuck in the app.
        NotificationCenter.default.addObserver(forName: TDService.uploadSpeedLimited, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let a = BackupActivity.shared
                guard a.isRunning, a.notice == nil else { return }
                a.notice = "Telegram limits upload speed for accounts without Premium. The backup continues, just slower."
            }
        }
    }

    private var rawDirectory: URL {
        let dir = env.stagingDirectory.appendingPathComponent("raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private func publish(_ change: @MainActor (BackupActivity) -> Void) { change(BackupActivity.shared) }

    /// Fails before the export when the phone can't hold the item's files and one upload part: copying a 10 GB video
    /// out of Photos onto a nearly full phone otherwise fails halfway with a vague Photos error.
    private func checkFreeSpace(for asset: PHAsset, name: String) async throws {
        guard let sizes = env.photos.exportSizes(of: asset), let free = CloudUploader.freeSpace(at: rawDirectory) else { return }
        let needed = PartLayout.spaceNeeded(exportSizes: sizes, encrypted: env.library.isEncrypted,
                                            limit: await env.td.uploadLimit()) + CloudUploader.spaceMargin
        guard free < needed else { return }
        appLog("Not enough space to back up \(name): needs \(needed >> 20) MB, \(free >> 20) MB free")
        throw NotEnoughSpaceError(needed: needed - free)
    }

    var isRunning: Bool { gate.withLock { running } }

    /// Why the queue can't run right now (nil = OK).
    @MainActor func blocker() -> StopReason? {
        if !env.isConfigured { return .notConfigured }
        if !PhotoLibraryService.hasAccess { return .noPhotoAccess }
        if !NetworkStatus.shared.isOnline { return .offline }
        if Prefs.wifiOnly && NetworkStatus.shared.isExpensive { return .waitingForWiFi }
        if Prefs.chargingOnly && !Device.isCharging { return .waitingForPower }
        return nil
    }

    // MARK: - Queue

    /// Adds phone assets that match the backup selection and aren't known yet as pending jobs.
    /// `among`: only these assets (Photos' change history), nil for the whole library.
    @discardableResult
    func enqueueNewAssets(force: Bool = false, among ids: Set<String>? = nil) -> Int {
        guard force || Prefs.autoBackup else { return 0 }
        let known = (try? env.store.knownLocalIdentifiers()) ?? []
        let fresh = env.photos.backupCandidates(among: ids).filter { !known.contains($0.localIdentifier) }
        let items = fresh.map(makeItem)
        try? env.store.upsert(items)
        return items.count
    }

    /// Removes queued items whose photo was deleted from the phone before it was uploaded (see
    /// `PhotoChangeScan.queuedButDeleted`). Only queue rows go; backed-up items and the cloud copies are untouched.
    @discardableResult
    func dropDeletedQueuedItems() -> Int {
        guard PhotoLibraryService.hasAccess, !DemoMode.isActive else { return 0 }
        let queued = (try? env.store.items(status: .queued)) ?? []
        let ids = queued.compactMap(\.localIdentifier)
        guard !ids.isEmpty else { return 0 }
        let present = env.photos.existingIdentifiers(ids)
        let gone = PhotoChangeScan.queuedButDeleted(queued, present: present, libraryIsEmpty: env.photos.fetchAllAssets().count == 0)
        for item in gone { try? env.store.delete(id: item.id) }
        if !gone.isEmpty { appLog("Dropped \(gone.count) queued items deleted from the phone") }
        return gone.count
    }

    // MARK: - Photos' change history (#31)

    private static let changeTokenKey = "photosChangeToken"
    private static let changeSelectionKey = "photosChangeSelection"
    private static let lastFullPhotoScanKey = "photosLastFullScan"

    /// One search for new and edited photos: the token to save once it's done, and the changes since the last search
    /// (nil when the whole library has to be read, see `PhotoChangeScan`).
    struct PhotoSearch {
        let token: Data?
        let changes: (inserted: Set<String>, updated: Set<String>)?
    }

    /// Everything that decides which photos are backed up; a change means photos that didn't change may now belong in.
    private var selectionFingerprint: String {
        [Prefs.mediaFilter.rawValue, Prefs.dateFrom.map { String(Int64($0.timeIntervalSince1970)) } ?? "-",
         String(Prefs.includeScreenshots), String(Prefs.includeHidden), Prefs.albumMode.rawValue,
         Prefs.albumIds.sorted().joined(separator: ",")].joined(separator: "|")
    }

    /// The token is taken before reading anything, so a photo taken during the search is found by the next one.
    private func beginPhotoSearch() -> PhotoSearch {
        let token = env.photos.changeToken()
        let saved = env.store.meta(Self.changeTokenKey).flatMap { Data(base64Encoded: $0) }
        let lastFull = env.store.meta(Self.lastFullPhotoScanKey).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        guard let saved, PhotoChangeScan.canUseChanges(hasToken: true, savedSelection: env.store.meta(Self.changeSelectionKey),
                                                       selection: selectionFingerprint, lastFullScan: lastFull, now: Date()) else {
            return PhotoSearch(token: token, changes: nil)
        }
        return PhotoSearch(token: token, changes: env.photos.changedAssets(since: saved))
    }

    private func finishPhotoSearch(_ search: PhotoSearch) {
        guard let token = search.token else { return }
        env.store.setMeta(Self.changeTokenKey, token.base64EncodedString())
        env.store.setMeta(Self.changeSelectionKey, selectionFingerprint)
        if search.changes == nil { env.store.setMeta(Self.lastFullPhotoScanKey, String(Date().timeIntervalSince1970)) }
    }

    /// After a reinstall the restored cloud items aren't linked to this iPhone's photos (the link lived only in
    /// the local database), so every photo looked "not backed up" and would be hashed again. Re-links them with
    /// `RestoreLinker` (caption asset id, else filename + capture second + pixel size) and drops queued
    /// duplicates of the linked photos. Returns the number of items linked.
    @discardableResult
    func relinkRestoredItems() -> Int {
        // Sign-in, app activation and library switches can all ask at once; one pass at a time is enough.
        relinkLock.lock()
        defer { relinkLock.unlock() }
        guard PhotoLibraryService.hasAccess, !DemoMode.isActive else { return 0 }
        let all = (try? env.store.allItems()) ?? []
        let unlinked = all.filter { $0.status == .backedUp && $0.localIdentifier == nil }
        guard !unlinked.isEmpty else { return 0 }
        let linked = Set(all.filter { $0.status == .backedUp }.compactMap(\.localIdentifier))
        let filter = RestoreLinker.Prefilter(unlinked: unlinked)
        var assets: [AssetKey] = []
        var namesLookedUp = 0
        let started = Date()
        env.photos.fetchAllAssets().enumerateObjects { asset, _, _ in
            guard !linked.contains(asset.localIdentifier) else { return }
            let name: String
            if filter.linksById(asset.localIdentifier) {
                name = ""
            } else if filter.needsFilename(creationDate: asset.creationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight),
                      let found = self.env.photos.originalResources(for: asset)?.primary.originalFilename {
                name = found
                namesLookedUp += 1
            } else {
                return
            }
            assets.append(AssetKey(localIdentifier: asset.localIdentifier, filename: name, creationDate: asset.creationDate,
                                   pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight))
        }
        appLog(String(format: "Relink: %d candidate photos, %d file names looked up, in %.1f s", assets.count, namesLookedUp, Date().timeIntervalSince(started)))
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
                if existing.status == .trashed {
                    // Still in the channel (Recently Deleted): backing it up again is just recovering it.
                    CloudTrash.recover(&existing)
                    items.append(existing)
                    continue
                }
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
            summary.error = "Backup is paused. Open Memvo and tap Back up now to resume."
            return summary
        }
        if DemoMode.isActive { return userStarted ? await runDemo(progress: progress) : summary }
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
        dropDeletedQueuedItems()
        if includeNew || Prefs.autoBackup {
            let started = Date()
            let search = beginPhotoSearch()
            let queued = enqueueNewAssets(force: true, among: search.changes.map { $0.inserted.union($0.updated) })
            let edited = requeueEditedSinceBackup(among: search.changes?.updated)
            finishPhotoSearch(search)
            let how = search.changes.map { "\($0.inserted.count) new and \($0.updated.count) changed photos from Photos' history" } ?? "the whole library"
            appLog(String(format: "Looked for new photos in %@: %d queued, %d edits to check, in %.1f s", how, queued, edited, Date().timeIntervalSince(started)))
        }

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
                        if isCancelled() || deadline.map({ Date() > $0 }) == true {
                            if await queue.drain() {
                                appLog("Backup stopped: \(isPauseRequested ? "paused" : (deadline.map { Date() > $0 } == true ? "out of time for this run" : "ended by iOS"))")
                            }
                            break
                        }
                        // A blip (Wi-Fi roaming, a moment of Low Data Mode) used to end the whole run after a few
                        // items; wait it out, and stop only if it lasts.
                        if let reason = await waitForConditions(isCancelled: isCancelled) {
                            await publish { $0.message = reason.localizedDescription }
                            if await queue.drain() { appLog("Backup stopped: \(reason.localizedDescription) (for over 2 minutes)") }
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
        if !isCancelled(), deadline.map({ Date() < $0 }) ?? true {
            await completeEarlierBackups(deadline: deadline, isCancelled: isCancelled)
            await makeEarlierScreenCopies(deadline: deadline, isCancelled: isCancelled)
            await env.library.writeSnapshotIfDue()
        }

        let counts = await counter.snapshot()
        summary.uploaded = counts.uploaded
        summary.alreadyBackedUp = counts.duplicate
        summary.failed = counts.failed
        summary.remaining = runnableItems(now: .distantFuture, onlyChosen: onlyChosen).count
        await env.enforceCacheLimits()
        await GalleryActions.emptyExpiredTrash()
        if summary.uploaded > 0 { UserDefaults.standard.set(Date(), forKey: Prefs.Key.lastBackupAt) }
        if isPauseRequested {
            summary.error = "Paused. \(summary.uploaded) backed up in this run; tap Back up now to continue where it stopped."
        }
        let final = summary
        await publish { a in a.isRunning = false; a.lastSummary = final; a.message = final.text; a.lanes = [:]; a.notice = nil }
        appLog("Backup run finished: \(summary.text)")
        return summary
    }

    /// App Review demo: "uploads" the demo's waiting items with real progress in the UI, without any network.
    /// The reviewer's own photos are never marked as backed up.
    private func runDemo(progress: (@Sendable (Int, Int) -> Void)?) async -> Summary {
        var summary = Summary()
        let alreadyRunning: Bool = gate.withLock {
            if running { return true }
            running = true
            return false
        }
        if alreadyRunning { summary.error = StopReason.alreadyRunning.localizedDescription; return summary }
        defer { gate.withLock { running = false } }
        let items = DemoMode.pendingItems()
        let total = items.count
        await publish { a in
            a.isRunning = true; a.done = 0; a.total = total; a.uploaded = 0; a.failed = 0; a.lanes = [:]
            a.message = total == 0 ? "Everything is backed up." : "Backing up \(total) items…"
        }
        for (i, original) in items.enumerated() {
            let lane = "\(i % Self.maxConcurrentUploads)"
            let size = original.fileSize
            for step in 1...10 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                await publish { $0.lanes[lane] = BackupActivity.LaneProgress(name: original.filename, sent: size * Int64(step) / 10, total: size) }
            }
            var item = original
            item.uploadedAt = Date()
            item.verifiedAt = Date()
            save(item)
            summary.uploaded += 1
            progress?(i + 1, total)
            let done = i + 1
            await publish { a in a.done = done; a.uploaded = done; a.lanes[lane] = nil }
        }
        DemoMode.pendingUploaded()
        if total > 0 { UserDefaults.standard.set(Date(), forKey: Prefs.Key.lastBackupAt) }
        let final = summary
        await publish { a in a.isRunning = false; a.lastSummary = final; a.message = final.text; a.lanes = [:] }
        appLog("Demo backup finished: \(final.text)")
        return summary
    }

    /// Moves every failed item back to pending (the "Retry failed" button).
    func retryFailed() {
        guard let failed = try? env.store.items(status: .failed) else { return }
        // Retrying is an explicit choice: these upload even when the rest of the queue is left alone.
        try? env.store.upsert(failed.map { var i = $0; i.job = JobMachine.reduce(i.job, .retry); i.chosen = true; return i })
    }

    /// Nil when the backup may go on; waits up to `patience` for a condition (offline, Wi-Fi only, charging only) to
    /// clear, telling the user what it's waiting for, and returns the reason if it doesn't.
    private func waitForConditions(isCancelled: () -> Bool, patience: TimeInterval = 120) async -> StopReason? {
        guard var reason = await blocker() else { return nil }
        // Both lanes wait for the same thing; one log line for it.
        let first = gate.withLock { waitingLanes += 1; return waitingLanes == 1 }
        defer { gate.withLock { waitingLanes -= 1 } }
        if first {
            let detail = reason == .waitingForWiFi ? " (\(NetworkStatus.shared.expenseDetail))" : ""
            appLog("Backup waiting: \(reason.localizedDescription)\(detail)")
        }
        let until = Date().addingTimeInterval(patience)
        while Date() < until, !isCancelled() {
            await publish { $0.message = reason.localizedDescription }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let still = await blocker() else {
                if first { appLog("Backup continuing") }
                await publish { $0.message = nil }
                return nil
            }
            reason = still
        }
        return reason
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
        if item.editCheck == true, item.cloudParts != nil {
            return await processEditUpdate(item, asset: asset, lane: lane)
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
            // Tried before and unchanged since: the duplicate check can use the stored hash before anything is exported
            // (a duplicate then never touches the file, which may have to come from iCloud Photos).
            if item.cloudParts == nil, !item.sha256.isEmpty, item.assetModifiedAt != nil, item.assetModifiedAt == asset.modificationDate,
               item.hasEdit != true || item.roleHashes?["e"] != nil,
               let twin = try env.store.items(sha256: item.sha256).first(where: {
                   $0.id != item.id && $0.status == .backedUp && Deduplicator.isSamePhoto(editHash: item.roleHashes?["e"], as: $0)
               }) {
                let missing = twin.localIdentifier.map { env.photos.asset(localIdentifier: $0) == nil } ?? true
                try env.store.delete(id: item.id)
                try Deduplicator(store: env.store).link(localIdentifier: localId, to: twin, existingAssetIsMissing: missing)
                appLog("\(item.filename) is already backed up (stored hash, not exported again)")
                return .duplicate
            }
            try await checkFreeSpace(for: asset, name: item.filename)
            let exp = try await env.photos.exportOriginal(of: asset, into: rawDirectory, extras: true)
            exported = exp

            // Content hash and de-duplication against everything already in the cloud. A retry of an unchanged photo
            // reuses the hashes from its last try: hashing a 3 GB video again took minutes of battery.
            let sizes = (primary: try CloudUploader.size(of: exp.primaryURL),
                         paired: try exp.pairedVideoURL.map { try CloudUploader.size(of: $0) },
                         edited: try exp.editedURL.map { try CloudUploader.size(of: $0) })
            let reuse = Deduplicator.canReuseHashes(of: item, modified: asset.modificationDate, sizes: sizes)
            if reuse { appLog("Reusing the stored hash of \(exp.primaryFilename) (unchanged since the last try)") }
            let primaryHash = reuse ? item.sha256 : try Deduplicator.sha256(of: exp.primaryURL)
            let pairedHash = reuse ? item.roleHashes?["pv"] : try exp.pairedVideoURL.map { try Deduplicator.sha256(of: $0) }
            let editedHash = reuse ? item.roleHashes?["e"] : try exp.editedURL.map { try Deduplicator.sha256(of: $0) }
            let twins = try env.store.items(sha256: primaryHash).filter { $0.id != item.id && $0.status == .backedUp }
            if item.cloudParts == nil, !twins.isEmpty, !twins.contains(where: { Deduplicator.isSamePhoto(editHash: editedHash, as: $0) }) {
                appLog("\(exp.primaryFilename) has the same original as a backed-up photo but a different edit: backing it up as its own photo")
            }
            if item.cloudParts == nil, let twin = twins.first(where: { Deduplicator.isSamePhoto(editHash: editedHash, as: $0) }) {
                let missing = twin.localIdentifier.map { env.photos.asset(localIdentifier: $0) == nil } ?? true
                try env.store.delete(id: item.id)
                try Deduplicator(store: env.store).link(localIdentifier: localId, to: twin, existingAssetIsMissing: missing)
                return .duplicate
            }
            item.sha256 = primaryHash
            item.filename = exp.primaryFilename
            item.kind = exp.kind
            item.uti = exp.primaryUTI
            item.fileSize = sizes.primary
            item.pairedVideoFilename = exp.pairedVideoFilename
            item.pairedVideoSize = sizes.paired
            item.hasEdit = exp.editedURL != nil ? true : nil
            item.editedFilename = exp.editedFilename
            item.editedSize = sizes.edited
            // Saved before the upload starts with the date they belong to (`assetModifiedAt` below), for a retry.
            var knownHashes = item.roleHashes ?? [:]
            knownHashes["o"] = primaryHash
            knownHashes["pv"] = pairedHash
            knownHashes["e"] = editedHash
            item.roleHashes = knownHashes
            item.encrypted = env.library.isEncrypted
            item.mimeType = exp.primaryFilename.mimeTypeForFilename
            if let video = await VideoInfo.inspect(asset: asset) {
                item.codec = video.codec
                item.hdr = video.hdr
            }
            item.tzOffsetMinutes = TimeZone.current.secondsFromGMT(for: asset.creationDate ?? Date()) / 60
            item.assetModifiedAt = asset.modificationDate
            item.albums = env.photos.albumNames(for: asset)
            item.hidden = asset.isHidden ? true : nil
            item.extrasChecked = true
            save(item)

            // Thumbnail: attached to the document (plain) or uploaded encrypted as role "t" (E2E).
            let thumbData = await env.photos.thumbnailJPEG(for: asset)
            let thumbURL = rawDirectory.appendingPathComponent("\(item.id)-thumb.jpg")
            var thumbSize = (320, 320)
            if let thumbData {
                try thumbData.write(to: thumbURL)
                if let px = ImageDimensions.pixelSize(of: thumbData) { thumbSize = (px.width, px.height) }
                _ = try? env.thumbnailCache.store(data: thumbData, for: CloudMediaService.thumbnailKey(item), ext: "jpg")
            }
            defer { try? FileManager.default.removeItem(at: thumbURL) }

            var originalMeta = captionMeta(item, role: .original, hash: primaryHash, name: item.filename, size: item.fileSize)
            // Albums that don't fit the caption go in a small md file instead of being dropped.
            var metadataFile: (url: URL, data: Data)?
            if try !CaptionCodec.keepsAlbums(originalMeta, captionKey: env.library.keys?.captionKey), let albums = originalMeta.a {
                let data = try ExtraMetadata(a: albums).encoded()
                metadataFile = (rawDirectory.appendingPathComponent("\(item.id)-md.json"), data)
                originalMeta.a = nil
            }
            var resources = [PreparedResource(role: "o", fileURL: exp.primaryURL, meta: originalMeta)]
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
            // The rest of what Photos keeps: edit recipe, RAW of a RAW + JPEG pair, edited Live Photo video.
            for extra in exp.extras {
                resources.append(try extraResource(item, extra))
            }
            if let metadataFile {
                try metadataFile.data.write(to: metadataFile.url)
                resources.append(PreparedResource(role: "md", fileURL: metadataFile.url,
                                                  meta: metadataMeta(item, hash: IndexCodec.sha256Hex(metadataFile.data), size: Int64(metadataFile.data.count))))
            }
            defer { if let metadataFile { try? FileManager.default.removeItem(at: metadataFile.url) } }

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
                    existing: item.parts(resource.role), resume: item.uploadResume?[resource.role],
                    checkpoint: { parts, expected, resume in
                        try store.update(id: itemId) { $0.setParts(parts, role: resource.role, expected: expected, resume: resume) }
                    },
                    progress: { [weak self] sent, _ in
                        let name = item.filename
                        Task { await self?.publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: name, sent: min(base + sent, streamTotal), total: streamTotal) } }
                    })
                item = (try store.item(id: itemId)) ?? item
                item.setParts(parts, role: resource.role, expected: parts.count)
                if !["o", "pv", "e", "t"].contains(resource.role) {
                    item.roleNames = (item.roleNames ?? [:]).merging([resource.role: resource.meta.n]) { $1 }
                }
                sentBefore += (try? CloudUploader.size(of: resource.fileURL)) ?? 0
            }

            item.job = JobMachine.reduce(item.job, .sent(sizeMatches: item.isCompleteInCloud))
            item.uploadedAt = Date()
            var hashes = ["o": primaryHash]
            if let pairedHash { hashes["pv"] = pairedHash }
            if let editedHash { hashes["e"] = editedHash }
            for r in resources where !["o", "pv", "e", "t"].contains(r.role) { hashes[r.role] = r.meta.h }
            item.roleHashes = hashes
            save(item)
            guard item.status == .backedUp else { return .failed }
            // The fast version, from the file that's already here: no extra download, so the video plays at once
            // from the cloud later. Optional: a failure never undoes the backup.
            if item.kind == .video, Prefs.streamingCopies, StreamingCopyPolicy.shouldMake(item), !isCancelled() {
                let source = exp.editedURL ?? exp.primaryURL
                let backedUp = item
                do {
                    // Same document thumbnail as the original, so it doesn't show as a blank file in Telegram.
                    _ = try await uploadStreamingCopy(backedUp, laneKey: laneKey,
                                                      thumbnail: thumbData != nil ? (thumbURL, thumbSize.0, thumbSize.1) : nil,
                                                      encode: { try await StreamingCopyEncoder.encode(AVURLAsset(url: source), to: $0) })
                } catch {
                    noteStreamingCopyFailure(error, backedUp)
                }
            }
            // A big photo's screen copy, from the file that's already here. Optional, like the fast version.
            if item.kind != .video, ScreenCopyPolicy.shouldMake(item), !isCancelled() {
                let backedUp = item
                do {
                    _ = try await uploadScreenCopy(backedUp, source: exp.editedURL ?? exp.primaryURL, laneKey: laneKey,
                                                   thumbnail: thumbData != nil ? (thumbURL, thumbSize.0, thumbSize.1) : nil)
                } catch {
                    noteScreenCopyFailure(error, backedUp)
                }
            }
            return .uploaded
        } catch {
            return fail(&item, error)
        }
    }

    // MARK: - Duplicates

    /// The same content backed up as more than one item (same SHA-256): `keep` stays, `extras` can go.
    struct CloudDuplicateGroup: Identifiable {
        let keep: MediaItem
        let extras: [MediaItem]
        var id: String { keep.id }
        var wastedBytes: Int64 { extras.reduce(0) { $0 + $1.fileSize + ($1.pairedVideoSize ?? 0) + ($1.editedSize ?? 0) } }
    }

    func cloudDuplicateGroups() -> [CloudDuplicateGroup] {
        let items = ((try? env.store.items(status: .backedUp)) ?? []).filter { !$0.sha256.isEmpty }
        let present = env.photos.existingIdentifiers(items.compactMap(\.localIdentifier))
        return Dictionary(grouping: items, by: \.sha256).values.compactMap { group in
            guard group.count > 1 else { return nil }
            // Keep the one linked to a photo on this iPhone, else the oldest upload.
            let sorted = group.sorted { a, b in
                let la = a.localIdentifier.map(present.contains) ?? false, lb = b.localIdentifier.map(present.contains) ?? false
                if la != lb { return la }
                return (a.uploadedAt ?? .distantFuture) < (b.uploadedAt ?? .distantFuture)
            }
            return CloudDuplicateGroup(keep: sorted[0], extras: Array(sorted.dropFirst()))
        }
        .sorted { ($0.keep.creationDate ?? .distantPast) > ($1.keep.creationDate ?? .distantPast) }
    }

    /// Deletes the extra items' messages from Telegram; their photos stay linked to the kept item.
    func removeCloudDuplicates(_ groups: [CloudDuplicateGroup]) async throws -> Int {
        guard let chatId = env.library.chatId else { throw LibraryError.noLibrary }
        var removed = 0
        for g in groups {
            for extra in g.extras {
                let ids = (extra.cloudParts ?? [:]).values.flatMap { $0.map(\.messageId) }
                if !ids.isEmpty { try await env.td.deleteMessages(chatId: chatId, ids: ids) }
                if let local = extra.localIdentifier {
                    try Deduplicator(store: env.store).link(localIdentifier: local, to: g.keep, existingAssetIsMissing: g.keep.localIdentifier == nil)
                }
                try env.store.delete(id: extra.id)
                removed += 1
            }
        }
        appLog("Removed \(removed) duplicate items from the library")
        return removed
    }

    /// Identical photos on this iPhone (found by content while backing up): the backed-up one plus its copies.
    struct PhoneDuplicateGroup: Identifiable {
        let item: MediaItem
        let original: String?
        let copies: [String]
        var id: String { item.id }
    }

    func phoneDuplicateGroups() -> [PhoneDuplicateGroup] {
        let aliases = (try? env.store.aliases()) ?? []
        let present = env.photos.existingIdentifiers(aliases.map(\.localIdentifier))
        let byItem = Dictionary(grouping: aliases.filter { present.contains($0.localIdentifier) }, by: \.itemId)
        let items = Dictionary(((try? env.store.items(ids: byItem.keys)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let originals = env.photos.existingIdentifiers(items.values.compactMap(\.localIdentifier))
        return byItem.compactMap { itemId, rows in
            guard let item = items[itemId] else { return nil }
            let original = item.localIdentifier.flatMap { originals.contains($0) ? $0 : nil }
            return PhoneDuplicateGroup(item: item, original: original, copies: rows.map(\.localIdentifier))
        }
        .sorted { ($0.item.creationDate ?? .distantPast) > ($1.item.creationDate ?? .distantPast) }
    }

    /// Deletes duplicate copies from the photo library (iOS asks to confirm) and forgets their aliases.
    func deletePhoneCopies(_ localIdentifiers: [String]) async throws -> Int {
        try await env.photos.deleteAssets(localIdentifiers)
        let still = env.photos.existingIdentifiers(localIdentifiers)
        let gone = localIdentifiers.filter { !still.contains($0) }
        for id in gone { try? env.store.removeAlias(localIdentifier: id) }
        return gone.count
    }

    // MARK: - Edited after backup

    /// Backed-up photos edited (again) in Photos since their backup: queue them so this run uploads the new
    /// edited version. Runs only for "Back up now" (or automatic backup). Returns how many were queued.
    /// `among`: only these photos (changed ones from Photos' history), nil for every backed-up photo.
    @discardableResult
    func requeueEditedSinceBackup(among changed: Set<String>? = nil) -> Int {
        guard PhotoLibraryService.hasAccess else { return 0 }
        if let changed, changed.isEmpty { return 0 }
        let items = ((try? env.store.items(status: .backedUp)) ?? []).filter {
            $0.cloudParts != nil && $0.localIdentifier.map { changed?.contains($0) ?? true } == true
        }
        let assets = env.photos.assets(localIdentifiers: items.compactMap(\.localIdentifier))
        var queued: [MediaItem] = []
        var unknownDate = 0
        for var item in items {
            guard let id = item.localIdentifier, let asset = assets[id] else { continue }
            let since = item.assetModifiedAt ?? item.uploadedAt
            // A newer date first: looking up the edit is the slow part, and most photos aren't edited.
            if let since, let modified = asset.modificationDate, modified <= since.addingTimeInterval(1) { continue }
            guard EditCheck.needsUpload(phoneHasEdit: env.photos.editedResource(for: asset) != nil,
                                        modified: asset.modificationDate, backedUpAt: since) else { continue }
            if since == nil { unknownDate += 1 }
            item.status = .queued
            item.editCheck = true
            queued.append(item)
        }
        // Copies linked to a backed-up photo as duplicates, edited while the cloud has no edit: taken for duplicates
        // before edits counted, they're backed up as their own photos.
        var editedCopies = 0
        let byId = Dictionary(((try? env.store.items(status: .backedUp)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let aliases = ((try? env.store.aliases()) ?? []).filter { changed?.contains($0.localIdentifier) ?? true }
        let aliasAssets = env.photos.assets(localIdentifiers: aliases.map(\.localIdentifier))
        for alias in aliases {
            guard let asset = aliasAssets[alias.localIdentifier], let twin = byId[alias.itemId], twin.hasEdit != true,
                  env.photos.editedResource(for: asset) != nil else { continue }
            try? env.store.removeAlias(localIdentifier: alias.localIdentifier)
            queued.append(makeItem(asset))
            editedCopies += 1
        }
        try? env.store.upsert(queued)
        if editedCopies > 0 { appLog("\(editedCopies) edited copies of backed-up photos will be backed up as their own photos") }
        if !queued.isEmpty {
            appLog("\(queued.count) backed-up items may have a newer edit on this device (\(unknownDate) without a known backup date); checking their edits")
        }
        return queued.count
    }

    /// Uploads the current edited version of an already backed-up item, replacing the previous one. The original
    /// is never touched. Nothing is uploaded when the edit is unchanged (e.g. only favourited).
    private func processEditUpdate(_ queued: MediaItem, asset: PHAsset, lane: Int) async -> Outcome {
        var item = queued
        let laneKey = "\(lane)"
        func finish(_ outcome: Outcome, handled: Bool = true) -> Outcome {
            item.editCheck = nil
            // Only a handled edit moves the marker; a failed one is re-checked on the next Back up now.
            if handled { item.assetModifiedAt = asset.modificationDate }
            item.status = item.isCompleteInCloud ? .backedUp : .failed
            save(item)
            return outcome
        }
        guard let resource = env.photos.editedResource(for: asset) else { return finish(.skipped) }
        await publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: "\(item.filename) (edit)", sent: 0, total: 0) }
        var exported: URL?
        defer {
            if let exported { try? FileManager.default.removeItem(at: exported) }
            Task { await self.publish { $0.lanes[laneKey] = nil } }
        }
        do {
            let url = try await env.photos.exportResource(resource, into: rawDirectory)
            exported = url
            let hash = try Deduplicator.sha256(of: url)
            if hash == item.roleHashes?["e"] { return finish(.duplicate) }

            // Remove the previous edit first, so a scan never picks the stale one; the original stays safe. The fast
            // version shows the edit too, so it goes as well and is made again from the new edit.
            // Only forget them once Telegram confirms: stale messages left without a local record would win a later
            // scan (it keeps the lowest message id). A failure throws, and the edit is checked again next run.
            let old = (item.parts("e") + item.parts("sp") + item.parts("d") + item.parts("ad") + item.parts("ad2") + item.parts("epv")).map(\.messageId)
            if !old.isEmpty {
                guard let chatId = env.library.chatId else { throw LibraryError.noLibrary }
                try await env.td.deleteMessages(chatId: chatId, ids: old)
            }
            item.cloudParts?["e"] = nil
            item.expectedParts?["e"] = nil
            item.cloudParts?["sp"] = nil
            item.expectedParts?["sp"] = nil
            item.streamingCopySkipped = nil
            item.cloudParts?["d"] = nil
            item.expectedParts?["d"] = nil
            item.screenCopySkipped = nil
            for role in ["ad", "ad2", "epv"] {
                item.cloudParts?[role] = nil
                item.expectedParts?[role] = nil
            }
            item.hasEdit = true
            item.editedFilename = resource.originalFilename
            item.editedSize = try CloudUploader.size(of: url)
            save(item)

            let store = env.store
            let itemId = item.id
            let size = item.editedSize ?? 0
            let name = item.filename
            let parts = try await env.uploader.upload(
                itemId: itemId,
                resource: PreparedResource(role: "e", fileURL: url,
                                           meta: captionMeta(item, role: .edited, hash: hash, name: resource.originalFilename, size: size)),
                encrypted: item.encrypted, thumbnail: nil, existing: [],
                checkpoint: { parts, expected, _ in try store.update(id: itemId) { $0.setParts(parts, role: "e", expected: expected) } },
                progress: { [weak self] sent, total in
                    Task { await self?.publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: "\(name) (edit)", sent: sent, total: total) } }
                })
            item = (try store.item(id: itemId)) ?? item
            item.setParts(parts, role: "e", expected: parts.count)
            var hashes = item.roleHashes ?? [:]
            hashes["e"] = hash
            item.roleHashes = hashes
            appLog("Uploaded the new edit of \(item.filename)")
            // The new edit's recipe and Live Photo video, so a restore shows this edit, revertible.
            let extras = (try? await env.photos.exportExtras(of: asset, into: rawDirectory, edit: true, skip: [.rawAlternate])) ?? []
            defer { for e in extras { try? FileManager.default.removeItem(at: e.url) } }
            for extra in extras {
                try await uploadExtra(item, extra, laneKey: laneKey)
                item = (try store.item(id: itemId)) ?? item
            }
            if ScreenCopyPolicy.shouldMake(item) {
                save(item)
                do { _ = try await uploadScreenCopy(item, source: url, laneKey: laneKey, thumbnail: nil) } catch { noteScreenCopyFailure(error, item) }
                item = (try? store.item(id: itemId)) ?? item
            }
            return finish(.uploaded)
        } catch {
            AppLog.shared.error("Uploading the new edit of \(item.filename) failed: \(error.localizedDescription)")
            item.lastError = "The newer edit couldn't be uploaded: \(error.localizedDescription)"
            return finish(.failed, handled: false)
        }
    }

    // MARK: - Fast versions (role `sp`)

    /// "Make Fast Version" in the viewer: the fast version of one video, now. A video that's no longer on this
    /// device is downloaded from Telegram first (the user asked for it; it stays in the viewing cache).
    func makeFastVersion(itemId: String) async throws {
        guard !DemoMode.isActive else { return }
        try await env.td.waitUntilReady(timeout: 20)
        guard let item = try env.store.item(id: itemId), item.status == .backedUp, item.kind == .video else {
            throw StreamingCopyError.unsupported
        }
        guard !item.hasStreamingCopy else { return }
        if let id = item.localIdentifier, let asset = env.photos.asset(localIdentifier: id) {
            _ = try await uploadStreamingCopy(item, laneKey: "copy", force: true,
                                              encode: { try await self.env.photos.exportStreamingCopy(of: asset, to: $0) })
            return
        }
        let role = VideoPlayback.role(.original, for: item)
        let name = role == "e" ? (item.editedFilename ?? item.filename) : item.filename
        let ext = (name as NSString).pathExtension.isEmpty ? "mov" : (name as NSString).pathExtension
        let source = rawDirectory.appendingPathComponent("\(item.id)-source.\(ext)")
        defer { try? FileManager.default.removeItem(at: source) }
        try await env.reader.download(item, role: role, to: source)
        _ = try await uploadStreamingCopy(item, laneKey: "copy", force: true,
                                          encode: { try await StreamingCopyEncoder.encode(AVURLAsset(url: source), to: $0) })
    }

    /// Encodes the fast version with `encode` and uploads it as role `sp`. Returns false (and never tries that video
    /// again) when it wouldn't be much smaller than the original, unless `force` (the user asked for it).
    private func uploadStreamingCopy(_ item: MediaItem, laneKey: String, force: Bool = false, thumbnail: (URL, Int, Int)? = nil,
                                     encode: (URL) async throws -> (url: URL, width: Int, height: Int)) async throws -> Bool {
        let store = env.store
        guard let chatId = env.library.chatId else { throw LibraryError.noLibrary }
        let itemId = item.id
        let name = "\((item.filename as NSString).deletingPathExtension)-fast.mp4"
        let label = "\(item.filename) (fast version)"
        await publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: label, sent: 0, total: 0) }
        let url = rawDirectory.appendingPathComponent("\(itemId)-fast.mp4")
        defer {
            try? FileManager.default.removeItem(at: url)
            Task { await self.publish { $0.lanes[laneKey] = nil } }
        }
        // Parts of an earlier, interrupted copy: a new encode isn't byte-identical, so start over.
        let stale = item.parts("sp").map(\.messageId)
        if !stale.isEmpty {
            try await env.td.deleteMessages(chatId: chatId, ids: stale)
            _ = try store.update(id: itemId) { $0.cloudParts?["sp"] = nil; $0.expectedParts?["sp"] = nil }
        }
        let copy = try await encode(url)
        let size = try CloudUploader.size(of: copy.url)
        guard force || StreamingCopyPolicy.isWorthKeeping(copyBytes: size, originalBytes: item.fileSize) else {
            _ = try? store.update(id: itemId) { $0.streamingCopySkipped = true }
            appLog("No fast version for \(item.filename): \(Format.bytes(size)) isn't much smaller than \(Format.bytes(item.fileSize))")
            return false
        }
        let hash = try Deduplicator.sha256(of: copy.url)
        var meta = captionMeta(item, role: .smoothPreview, hash: hash, name: name, size: size)
        meta.wh = [copy.width, copy.height]
        meta.c = "hevc"
        meta.hdr = nil
        meta.m = "video/mp4"
        let parts = try await env.uploader.upload(
            itemId: itemId, resource: PreparedResource(role: "sp", fileURL: copy.url, meta: meta),
            encrypted: item.encrypted, thumbnail: thumbnail, existing: [],
            checkpoint: { parts, expected, _ in try store.update(id: itemId) { $0.setParts(parts, role: "sp", expected: expected) } },
            progress: { [weak self] sent, total in
                Task { await self?.publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: label, sent: sent, total: total) } }
            })
        _ = try store.update(id: itemId) {
            $0.setParts(parts, role: "sp", expected: parts.count)
            $0.streamingCopySkipped = nil
            var hashes = $0.roleHashes ?? [:]
            hashes["sp"] = hash
            $0.roleHashes = hashes
        }
        appLog("Uploaded the fast version of \(item.filename): \(Format.bytes(size)) for a \(Format.bytes(item.fileSize)) original")
        return true
    }

    // MARK: - Everything Photos keeps (roles `ad`, `ad2`, `ra`, `epv`)

    /// Items backed up before the edit recipe, RAW alternates and edited Live Photo videos were stored get them now, a
    /// few at a time at the end of a run, from the photo still on this device (never from iCloud Photos). Each item is
    /// checked once; one whose photo is gone has nothing left to add.
    private func completeEarlierBackups(deadline: Date?, isCancelled: @escaping @Sendable () -> Bool, limit: Int = 50) async {
        guard !DemoMode.isActive, env.library.chatId != nil else { return }
        let candidates = ((try? env.store.items(status: .backedUp)) ?? [])
            .filter { $0.cloudParts != nil && $0.extrasChecked != true && $0.localIdentifier != nil }
            .prefix(limit)
        guard !candidates.isEmpty else { return }
        let assets = env.photos.assets(localIdentifiers: candidates.compactMap(\.localIdentifier))
        var completed = 0
        for item in candidates {
            if isCancelled() || deadline.map({ Date() > $0 }) == true { break }
            if await blocker() != nil { break }
            guard let id = item.localIdentifier, let asset = assets[id] else {
                _ = try? env.store.update(id: item.id) { $0.extrasChecked = true }
                continue
            }
            var skip: Set<CaptionMeta.Role> = []
            if !item.parts("ra").isEmpty { skip.insert(.rawAlternate) }
            if !item.parts("ad").isEmpty { skip.formUnion([.adjustment, .adjustmentSecondary]) }
            if !item.parts("epv").isEmpty { skip.insert(.editedPairedVideo) }
            let edited = item.hasEdit == true && !item.parts("e").isEmpty
            do {
                let extras = try await env.photos.exportExtras(of: asset, into: rawDirectory, edit: edited, allowNetwork: false, skip: skip)
                defer { for e in extras { try? FileManager.default.removeItem(at: e.url) } }
                for extra in extras {
                    await waitForFloodPause(isCancelled: isCancelled)
                    await paceUploadStart()
                    try await uploadExtra(item, extra, laneKey: "copy")
                }
                _ = try? env.store.update(id: item.id) { $0.extrasChecked = true }
                if !extras.isEmpty { completed += 1 }
            } catch {
                // Not on the device (only in iCloud Photos) or a network error: checked again on a later run.
                AppLog.shared.warn("Couldn't complete the backup of \(item.filename) yet: \(error.localizedDescription)")
                if case .floodWait(let s)? = (error as? TDServiceError)?.kind {
                    gate.withLock { pausedUntil = max(pausedUntil, Date().addingTimeInterval(TimeInterval(s))) }
                    break
                }
            }
        }
        if completed > 0 { appLog("Added what Photos keeps (edits, RAW) to \(completed) earlier backup\(completed == 1 ? "" : "s")") }
    }

    /// Uploads one extra file of an already backed-up item under its role.
    private func uploadExtra(_ item: MediaItem, _ extra: ExportedExtra, laneKey: String) async throws {
        let store = env.store
        let itemId = item.id
        let resource = try extraResource(item, extra)
        let label = "\(item.filename) (\(extra.filename))"
        await publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: label, sent: 0, total: 0) }
        defer { Task { await self.publish { $0.lanes[laneKey] = nil } } }
        let parts = try await env.uploader.upload(
            itemId: itemId, resource: resource, encrypted: item.encrypted, thumbnail: nil, existing: item.parts(resource.role),
            resume: item.uploadResume?[resource.role],
            checkpoint: { parts, expected, resume in
                try store.update(id: itemId) { $0.setParts(parts, role: resource.role, expected: expected, resume: resume) }
            },
            progress: { [weak self] sent, total in
                Task { await self?.publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: label, sent: sent, total: total) } }
            })
        _ = try store.update(id: itemId) {
            $0.setParts(parts, role: resource.role, expected: parts.count)
            $0.roleHashes = ($0.roleHashes ?? [:]).merging([resource.role: resource.meta.h]) { $1 }
            $0.roleNames = ($0.roleNames ?? [:]).merging([resource.role: resource.meta.n]) { $1 }
        }
    }

    // MARK: - Screen copies (role `d`)

    /// Photos backed up before screen copies existed get one a few at a time at the end of a run, made from a file that
    /// is already on this device: the photo in the library, or the original downloaded for viewing. Nothing is downloaded
    /// just for this, and nothing about the photo changes if it can't be made.
    private func makeEarlierScreenCopies(deadline: Date?, isCancelled: @escaping @Sendable () -> Bool, limit: Int = 20) async {
        guard !DemoMode.isActive, env.library.chatId != nil else { return }
        let candidates = ((try? env.store.items(status: .backedUp)) ?? []).filter { $0.cloudParts != nil && ScreenCopyPolicy.shouldMake($0) }
        guard !candidates.isEmpty else { return }
        let assets = env.photos.assets(localIdentifiers: candidates.compactMap(\.localIdentifier))
        var made = 0
        for item in candidates where made < limit {
            if isCancelled() || deadline.map({ Date() > $0 }) == true { break }
            if await blocker() != nil { break }
            await waitForFloodPause(isCancelled: isCancelled)
            var exported: URL?
            defer { if let exported { try? FileManager.default.removeItem(at: exported) } }
            let source: URL
            if let cached = env.media.cachedDisplayed(item) {
                source = cached
            } else if let id = item.localIdentifier, let asset = assets[id],
                      let resource = env.photos.editedResource(for: asset) ?? env.photos.originalResources(for: asset)?.primary,
                      // Only what's on the phone already: never download from iCloud Photos just for a screen copy.
                      let url = try? await env.photos.exportResource(resource, into: rawDirectory, allowNetwork: false) {
                exported = url
                source = url
            } else {
                continue
            }
            await paceUploadStart()
            do {
                if try await uploadScreenCopy(item, source: source, laneKey: "copy", thumbnail: nil) { made += 1 }
            } catch {
                noteScreenCopyFailure(error, item)
                if case .floodWait? = (error as? TDServiceError)?.kind { break }
            }
        }
        if made > 0 { appLog("Made screen copies for \(made) earlier photo\(made == 1 ? "" : "s")") }
    }

    /// Makes the screen copy of `item` from `source` (what the viewer shows: the edit, else the original) and uploads it
    /// as role `d`. Returns false (and never tries that photo again) when it wouldn't be much smaller.
    private func uploadScreenCopy(_ item: MediaItem, source: URL, laneKey: String, thumbnail: (URL, Int, Int)?) async throws -> Bool {
        let store = env.store
        guard let chatId = env.library.chatId else { throw LibraryError.noLibrary }
        let itemId = item.id
        let shown = ScreenCopyPolicy.shown(item)
        let name = "\((shown.name as NSString).deletingPathExtension)-screen.jpg"
        let label = "\(item.filename) (screen copy)"
        await publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: label, sent: 0, total: 0) }
        let url = rawDirectory.appendingPathComponent("\(itemId)-screen.jpg")
        defer {
            try? FileManager.default.removeItem(at: url)
            Task { await self.publish { $0.lanes[laneKey] = nil } }
        }
        // Parts of an earlier, interrupted copy: a new encode isn't byte-identical, so start over.
        let stale = item.parts("d").map(\.messageId)
        if !stale.isEmpty {
            try await env.td.deleteMessages(chatId: chatId, ids: stale)
            _ = try store.update(id: itemId) { $0.cloudParts?["d"] = nil; $0.expectedParts?["d"] = nil }
        }
        let copy = try ScreenCopyEncoder.encode(source, to: url)
        let size = try CloudUploader.size(of: copy.url)
        guard ScreenCopyPolicy.isWorthKeeping(copyBytes: size, originalBytes: shown.size) else {
            _ = try? store.update(id: itemId) { $0.screenCopySkipped = true }
            appLog("No screen copy for \(item.filename): \(Format.bytes(size)) isn't much smaller than \(Format.bytes(shown.size))")
            return false
        }
        let hash = try Deduplicator.sha256(of: copy.url)
        var meta = captionMeta(item, role: .screenCopy, hash: hash, name: name, size: size)
        meta.wh = [copy.width, copy.height]
        meta.m = "image/jpeg"
        let parts = try await env.uploader.upload(
            itemId: itemId, resource: PreparedResource(role: "d", fileURL: copy.url, meta: meta),
            encrypted: item.encrypted, thumbnail: thumbnail, existing: [],
            checkpoint: { parts, expected, _ in try store.update(id: itemId) { $0.setParts(parts, role: "d", expected: expected) } },
            progress: { [weak self] sent, total in
                Task { await self?.publish { $0.lanes[laneKey] = BackupActivity.LaneProgress(name: label, sent: sent, total: total) } }
            })
        _ = try store.update(id: itemId) {
            $0.setParts(parts, role: "d", expected: parts.count)
            $0.screenCopySkipped = nil
            var hashes = $0.roleHashes ?? [:]
            hashes["d"] = hash
            $0.roleHashes = hashes
        }
        appLog("Uploaded the screen copy of \(item.filename): \(Format.bytes(size)) for a \(Format.bytes(shown.size)) photo")
        return true
    }

    /// A screen copy is optional: a failure never touches the item. Only a photo that can't be decoded is left alone from
    /// then on; anything else (network, disk full, the app suspended) is tried again later.
    private func noteScreenCopyFailure(_ error: Error, _ item: MediaItem) {
        if error is CancellationError { return }
        if let td = error as? TDServiceError {
            if case .cancelled = td { return }
            if case .floodWait(let s) = td.kind {
                gate.withLock { pausedUntil = max(pausedUntil, Date().addingTimeInterval(TimeInterval(s))) }
            }
            AppLog.shared.warn("Screen copy of \(item.filename) will be retried: \(error.localizedDescription)")
            return
        }
        if error is ScreenCopyError { _ = try? env.store.update(id: item.id) { $0.screenCopySkipped = true } }
        AppLog.shared.warn("No screen copy for \(item.filename)\(error is ScreenCopyError ? "" : " yet"): \(error.localizedDescription)")
    }

    private static let unconvertibleAVErrors: Set<AVError.Code> = [.fileFormatNotRecognized, .decoderNotFound, .encoderNotFound, .decodeFailed]

    /// A fast version is optional: a failure never touches the item. Only a video that can't be converted at all is
    /// left alone from then on; anything else (network, disk full, the app suspended mid-encode) is tried later.
    private func noteStreamingCopyFailure(_ error: Error, _ item: MediaItem) {
        if error is CancellationError { return }
        if let td = error as? TDServiceError {
            if case .cancelled = td { return }
            if case .floodWait(let s) = td.kind {
                gate.withLock { pausedUntil = max(pausedUntil, Date().addingTimeInterval(TimeInterval(s))) }
            }
            AppLog.shared.warn("Fast version of \(item.filename) will be retried: \(error.localizedDescription)")
            return
        }
        let unconvertible = error is StreamingCopyError || Self.unconvertibleAVErrors.contains((error as? AVError)?.code ?? .unknown)
        if unconvertible { _ = try? env.store.update(id: item.id) { $0.streamingCopySkipped = true } }
        AppLog.shared.warn("No fast version for \(item.filename)\(unconvertible ? "" : " yet"): \(error.localizedDescription)")
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
        // Not enough space: retrying in this run would export the file again and fail the same way.
        else if error is CryptoError || error is PhotoLibraryError || error is LibraryError || error is NotEnoughSpaceError { kind = .permanent }
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

    /// Caption for an extra file (`ad`, `ad2`, `ra`, `epv`): describes the file itself.
    private func extraResource(_ item: MediaItem, _ extra: ExportedExtra) throws -> PreparedResource {
        var meta = captionMeta(item, role: extra.role, hash: try Deduplicator.sha256(of: extra.url), name: extra.filename,
                               size: try CloudUploader.size(of: extra.url))
        meta.a = nil
        if extra.role != .rawAlternate { meta.wh = nil }
        return PreparedResource(role: extra.role.rawValue, fileURL: extra.url, meta: meta)
    }

    private func metadataMeta(_ item: MediaItem, hash: String, size: Int64) -> CaptionMeta {
        var meta = captionMeta(item, role: .metadata, hash: hash, name: "metadata.json", size: size)
        meta.m = "application/json"
        meta.a = nil
        meta.wh = nil
        return meta
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
        m.hid = item.hidden == true ? 1 : nil
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
    /// Empties the queue; true for the lane that actually stopped it (so the reason is logged once).
    @discardableResult
    func drain() -> Bool {
        defer { items.removeAll() }
        return !items.isEmpty
    }

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
