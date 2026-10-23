import Foundation
import Photos
import CloudGalleryCore

/// Live state for the UI (Backup tab, progress bars).
@MainActor
final class BackupActivity: ObservableObject {
    static let shared = BackupActivity()
    @Published var isPreparing = false
    @Published var prepared = 0
    @Published var total = 0
    @Published var inFlight = 0
    @Published var message: String?
    @Published var lastSummary: BackupEngine.Summary?
}

/// Scans the library, exports originals, de-duplicates, and hands multipart bodies to the background uploader.
/// An item becomes `.backedUp` only after Telegram has confirmed every required message with a file_id.
final class BackupEngine: @unchecked Sendable {
    struct Summary: Equatable {
        var queued = 0
        var alreadyBackedUp = 0
        var tooLarge = 0
        var failed = 0
        var remaining = 0
        var inFlight = 0
        var error: String?

        var text: String {
            if let error { return error }
            var parts = ["Queued \(queued) item\(queued == 1 ? "" : "s")"]
            if alreadyBackedUp > 0 { parts.append("\(alreadyBackedUp) already backed up") }
            if tooLarge > 0 { parts.append("\(tooLarge) too large (need version 2)") }
            if failed > 0 { parts.append("\(failed) failed") }
            if remaining > 0 { parts.append("\(remaining) left for later") }
            return parts.joined(separator: ", ") + "."
        }
    }

    enum Outcome { case queued, duplicate, tooLarge, failed(Error) }

    /// Keep at most this much prepared data on disk waiting to upload.
    static let stagingBudget: Int64 = 1_500 * 1024 * 1024
    /// Multipart headers add a little; stay safely under the 50 MB limit.
    static let uploadLimit: Int64 = TelegramClient.maxUploadBytes - 64 * 1024

    private unowned let env: AppEnvironment
    private let gate = NSLock()
    private var running = false
    private let backoff = BackoffPolicy()

    init(environment: AppEnvironment) {
        self.env = environment
        env.uploader.onJobFinished = { [weak self] job, result in self?.handle(job: job, result: result) }
        env.uploader.onAllEventsDelivered = { [weak self] in
            Task { await self?.syncIndexIfIdle() }
        }
    }

    private var rawDirectory: URL {
        let dir = env.stagingDirectory.appendingPathComponent("raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stagingBytes() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: env.stagingDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    @MainActor private func publish(_ change: @MainActor (BackupActivity) -> Void) { change(BackupActivity.shared) }

    // MARK: - Queueing

    /// Prepares and enqueues new/unfinished items until done, `deadline` passes, the staging budget is full,
    /// or `isCancelled` returns true. Safe to call from the UI, App Intents and BGTasks; concurrent calls return early.
    func queueNewItems(deadline: Date? = nil, maxItems: Int? = nil,
                       isCancelled: @escaping () -> Bool = { false },
                       progress: ((Int, Int) -> Void)? = nil) async -> Summary {
        var summary = Summary()
        guard env.isConfigured else { summary.error = "CloudGallery isn't set up yet. Open the app to connect your bot."; return summary }
        guard PhotoLibraryService.hasAccess else { summary.error = "CloudGallery has no access to your photos."; return summary }

        gate.lock()
        if running { gate.unlock(); summary.error = "A backup is already running."; return summary }
        running = true
        gate.unlock()
        defer { gate.lock(); running = false; gate.unlock() }

        let inFlightJobs = await env.uploader.inFlightJobs()
        let inFlightIds = Set(inFlightJobs.map(\.itemId))
        summary.inFlight = inFlightJobs.count

        // Unfinished items (failed, interrupted, or tasks lost when the app was force-quit).
        let unfinished = ((try? env.store.items(status: .failed)) ?? []) +
                         ((try? env.store.items(status: .queued)) ?? []) +
                         ((try? env.store.items(status: .uploading)) ?? []).filter { !inFlightIds.contains($0.id) }
        let known = (try? env.store.knownLocalIdentifiers()) ?? []
        let fresh = env.photos.backupCandidates().filter { !known.contains($0.localIdentifier) }

        var work: [(PHAsset, MediaItem?)] = []
        let retryIds = unfinished.compactMap(\.localIdentifier)
        var retryAssets: [String: PHAsset] = [:]
        if !retryIds.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: retryIds, options: nil).enumerateObjects { a, _, _ in retryAssets[a.localIdentifier] = a }
        }
        for item in unfinished {
            if let id = item.localIdentifier, let asset = retryAssets[id] { work.append((asset, item)) }
        }
        work += fresh.map { ($0, nil) }

        let total = maxItems.map { min($0, work.count) } ?? work.count
        await publish { $0.isPreparing = true; $0.prepared = 0; $0.total = total; $0.message = "Preparing \(total) items…" }
        appLog("Backup run: \(fresh.count) new, \(unfinished.count) unfinished, \(inFlightJobs.count) uploads in flight")

        var processed = 0
        for (asset, existing) in work {
            if processed >= total || isCancelled() { break }
            if let deadline, Date() > deadline { break }
            if stagingBytes() > Self.stagingBudget { appLog("Staging budget full; pausing preparation"); break }

            let outcome = await prepare(asset: asset, existing: existing)
            switch outcome {
            case .queued: summary.queued += 1
            case .duplicate: summary.alreadyBackedUp += 1
            case .tooLarge: summary.tooLarge += 1
            case .failed(let e):
                summary.failed += 1
                AppLog.shared.error("Preparing \(asset.localIdentifier) failed: \(e.localizedDescription)")
            }
            processed += 1
            progress?(processed, total)
            let done = processed
            await publish { $0.prepared = done }
        }
        summary.remaining = work.count - processed
        summary.inFlight = await env.uploader.allTasks().count
        let final = summary
        await publish { $0.isPreparing = false; $0.lastSummary = final; $0.message = final.text; $0.inFlight = final.inFlight }
        appLog("Backup run finished: \(summary.text)")
        return summary
    }

    /// Keeps preparing until nothing is left and every upload has finished (used by the continued-processing task).
    func runToCompletion(isCancelled: @escaping () -> Bool, progress: @escaping (_ done: Int, _ total: Int) -> Void) async -> Summary {
        var combined = Summary()
        let startCounts = (try? env.store.counts()) ?? [:]
        let startBacked = startCounts[.backedUp] ?? 0
        let pending = env.photos.backupCandidates().count - ((try? env.store.knownLocalIdentifiers().count) ?? 0)
        let target = max(1, pending + (startCounts[.failed] ?? 0) + (startCounts[.queued] ?? 0) + (startCounts[.uploading] ?? 0))

        func report() {
            let now = ((try? env.store.counts()) ?? [:])
            let done = (now[.backedUp] ?? 0) - startBacked + (now[.tooLarge] ?? 0) - (startCounts[.tooLarge] ?? 0)
            progress(min(max(0, done), target), target)
        }

        while !isCancelled() {
            let s = await queueNewItems(isCancelled: isCancelled) { _, _ in report() }
            combined.queued += s.queued
            combined.alreadyBackedUp += s.alreadyBackedUp
            combined.tooLarge += s.tooLarge
            combined.failed += s.failed
            combined.error = s.error
            if s.error != nil && s.queued == 0 { break }
            // Wait for uploads to drain (or free staging space) before the next round.
            repeat {
                report()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } while !isCancelled() && stagingBytes() > Self.stagingBudget / 2
            let inFlight = await env.uploader.allTasks().count
            if s.remaining == 0 && inFlight == 0 { break }
            if s.remaining == 0 && s.queued == 0 && s.failed == 0 {
                // Only waiting for the last uploads.
                while !isCancelled(), await env.uploader.allTasks().count > 0 {
                    report()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                break
            }
        }
        report()
        await syncIndexIfIdle()
        return combined
    }

    // MARK: - Preparing one asset

    private func prepare(asset: PHAsset, existing: MediaItem?) async -> Outcome {
        let exported: ExportedAsset
        do {
            exported = try await env.photos.exportOriginal(of: asset, into: rawDirectory)
        } catch {
            if let existing { markFailed(existing.id, error) }
            return .failed(error)
        }
        defer { exported.cleanup() }

        do {
            let fm = FileManager.default
            let primarySize = (try fm.attributesOfItem(atPath: exported.primaryURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let pairedSize = try exported.pairedVideoURL.map { (try fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value ?? 0 }
            var hashes = [try Deduplicator.sha256(of: exported.primaryURL)]
            if let paired = exported.pairedVideoURL { hashes.append(try Deduplicator.sha256(of: paired)) }
            let sha = Deduplicator.combinedHash(hashes)

            var item: MediaItem
            if let existing {
                item = existing
            } else {
                let dedupe = Deduplicator(store: env.store)
                switch try dedupe.decide(localIdentifier: asset.localIdentifier, sha256: sha) {
                case .known:
                    return .duplicate
                case .duplicateContent(let match):
                    let missing = match.localIdentifier.map { env.photos.asset(localIdentifier: $0) == nil } ?? true
                    try dedupe.link(localIdentifier: asset.localIdentifier, to: match, existingAssetIsMissing: missing)
                    return .duplicate
                case .upload:
                    item = MediaItem(localIdentifier: asset.localIdentifier, sha256: sha, filename: exported.primaryFilename,
                                       kind: exported.kind, uti: exported.primaryUTI, creationDate: asset.creationDate,
                                       latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
                                       pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                       duration: asset.mediaType == .video ? asset.duration : nil,
                                       fileSize: primarySize, encrypted: Prefs.encryptionEnabled, status: .queued)
                    item.pairedVideoFilename = exported.pairedVideoFilename
                    item.pairedVideoSize = pairedSize
                }
            }
            // Nothing confirmed yet for a retried item: refresh content (it may have been edited) and settings.
            if existing != nil && item.original == nil {
                item.sha256 = sha
                item.fileSize = primarySize
                item.pairedVideoSize = pairedSize
                item.kind = exported.kind
                if item.encrypted != Prefs.encryptionEnabled {
                    item.encrypted = Prefs.encryptionEnabled
                    item.thumbnail = nil
                    item.pairedVideo = nil
                }
            }

            // Bot API limit: refuse anything over 50 MB — never pretend it is backed up.
            let uploadSize: (Int64) -> Int64 = { item.encrypted ? FileCrypto.encryptedSize(plaintextSize: $0) : $0 }
            if uploadSize(primarySize) > Self.uploadLimit || uploadSize(pairedSize ?? 0) > Self.uploadLimit {
                item.status = .tooLarge
                item.lastError = "Larger than the Bot API's 50 MB upload limit. Needs version 2."
                try env.store.upsert(item)
                return .tooLarge
            }

            guard let thumb = await env.photos.thumbnailJPEG(for: asset) else {
                throw PhotoLibraryError.noOriginalResource
            }

            let roles = item.requiredRoles.filter { item.remote(for: $0) == nil }
            var jobs: [UploadJob] = []
            for role in roles {
                let source: URL
                let plainName: String
                switch role {
                case .original:
                    source = exported.primaryURL
                    plainName = item.filename
                case .pairedVideo:
                    guard let url = exported.pairedVideoURL else { continue }
                    source = url
                    plainName = item.pairedVideoFilename ?? "\((item.filename as NSString).deletingPathExtension).MOV"
                case .thumbnail:
                    source = rawDirectory.appendingPathComponent("\(item.id)-thumb.jpg")
                    try thumb.write(to: source)
                    plainName = "\((item.filename as NSString).deletingPathExtension).thumb.jpg"
                }
                jobs.append(try buildJob(item: item, role: role, source: source, plainName: plainName))
                if role == .thumbnail { try? fm.removeItem(at: source) }
            }

            item.status = .uploading
            item.attempts += 1
            item.lastError = nil
            try env.store.upsert(item)

            for job in jobs {
                let delay = await env.limiter.reserve()
                try env.uploader.enqueue(job, delay: delay)
            }
            return .queued
        } catch {
            if let existing { markFailed(existing.id, error) }
            return .failed(error)
        }
    }

    private func buildJob(item: MediaItem, role: UploadRole, source: URL, plainName: String) throws -> UploadJob {
        guard let chatId = env.chatId else { throw TelegramError.api(code: 401, description: "Not configured") }
        var payload = source
        var fileName = plainName
        var mime = plainName.mimeTypeForFilename
        var encryptedTemp: URL?
        if item.encrypted {
            let out = rawDirectory.appendingPathComponent("\(item.id)-\(role.rawValue).cge")
            try FileCrypto.encrypt(input: source, output: out, masterKey: try env.fileMasterKey())
            payload = out
            encryptedTemp = out
            fileName = "\(item.id)-\(role.rawValue).cge"
            mime = "application/octet-stream"
        }
        defer { if let encryptedTemp { try? FileManager.default.removeItem(at: encryptedTemp) } }

        let bodyFile = "\(item.id)-\(role.rawValue).body"
        let body = MultipartBody()
        try body.write(fields: [("chat_id", chatId),
                                ("caption", item.caption(for: role)),
                                ("disable_notification", "true"),
                                ("disable_content_type_detection", "true")],
                       file: .init(fieldName: "document", fileName: fileName, mimeType: mime, fileURL: payload),
                       to: env.stagingDirectory.appendingPathComponent(bodyFile))
        return UploadJob(itemId: item.id, role: role, bodyFile: bodyFile, contentType: body.contentType, attempt: 0)
    }

    private func markFailed(_ id: String, _ error: Error) {
        _ = try? env.store.update(id: id) {
            $0.status = .failed
            $0.lastError = error.localizedDescription
        }
    }

    // MARK: - Upload completion

    func handle(job: UploadJob, result: Result<TGMessage, Error>) {
        let body = env.uploader.bodyURL(job)
        switch result {
        case .success(let message):
            try? FileManager.default.removeItem(at: body)
            do {
                let remote = try RemoteFile(message: message)
                let updated = try env.store.update(id: job.itemId) { item in
                    item.setRemote(remote, for: job.role)
                    if item.isFullyUploaded {
                        item.status = .backedUp
                        item.uploadedAt = Date()
                        item.lastError = nil
                    }
                }
                if updated?.status == .backedUp {
                    markIndexDirty()
                    UserDefaults.standard.set(Date(), forKey: Prefs.Key.lastBackupAt)
                }
            } catch {
                AppLog.shared.error("Upload \(job.role.rawValue) of \(job.itemId) returned no document: \(error)")
                markFailed(job.itemId, error)
            }
        case .failure(let error):
            if error is CancellationError {
                try? FileManager.default.removeItem(at: body)
                return
            }
            Task {
                if case TelegramError.rateLimited(let s) = error { await env.limiter.penalize(retryAfter: TimeInterval(s)) }
                switch backoff.decide(error: error, attempt: job.attempt) {
                case .retry(let after):
                    var next = job
                    next.attempt += 1
                    let slot = await env.limiter.reserve()
                    do {
                        guard FileManager.default.fileExists(atPath: body.path) else { throw PhotoLibraryError.noOriginalResource }
                        try env.uploader.enqueue(next, delay: max(after, slot))
                        appLog("Retrying \(job.role.rawValue) of \(job.itemId) in \(Int(max(after, slot)))s (\(error.localizedDescription))")
                    } catch {
                        markFailed(job.itemId, error)
                    }
                case .giveUp:
                    try? FileManager.default.removeItem(at: body)
                    AppLog.shared.error("Giving up on \(job.role.rawValue) of \(job.itemId): \(error.localizedDescription)")
                    markFailed(job.itemId, error)
                }
            }
        }
    }

    // MARK: - Index

    func markIndexDirty() { env.store.setMeta("indexDirty", "1") }
    var isIndexDirty: Bool { env.store.meta("indexDirty") == "1" }

    /// Uploads the index once no uploads are pending (end of a batch).
    func syncIndexIfIdle() async {
        let inFlight = await env.uploader.allTasks().count
        await publish { $0.inFlight = inFlight }
        guard inFlight == 0, isIndexDirty else { return }
        do {
            try await env.indexSync.upload()
        } catch {
            AppLog.shared.error("Index upload failed: \(error.localizedDescription)")
        }
    }
}
