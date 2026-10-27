import Foundation
import Testing
import MemvoCore

@Suite struct DedupeTests {
    func item(_ local: String?, sha: String, status: ItemStatus = .backedUp) -> MediaItem {
        MediaItem(localIdentifier: local, sha256: sha, filename: "a.jpg", kind: .photo, creationDate: Date(), fileSize: 10, status: status)
    }

    @Test func unknownAssetUploads() throws {
        let store = try LibraryStore(url: nil)
        let d = Deduplicator(store: store)
        #expect(try d.check(localIdentifier: "A") == nil)
        #expect(try d.decide(localIdentifier: "A", sha256: "h1") == .upload)
    }

    @Test func knownLocalIdentifierIsSkipped() throws {
        let store = try LibraryStore(url: nil)
        let existing = item("A", sha: "h1")
        try store.upsert(existing)
        let d = Deduplicator(store: store)
        #expect(try d.check(localIdentifier: "A")?.id == existing.id)
        guard case .known(let known) = try d.decide(localIdentifier: "A", sha256: "anything") else {
            Issue.record("expected known"); return
        }
        #expect(known.id == existing.id)
    }

    @Test func sameBytesAfterReinstallAreLinkedNotUploaded() throws {
        // Restored index knows the hash but the identifier differs (new device).
        let store = try LibraryStore(url: nil)
        let restored = item("OLD-DEVICE-ID", sha: "h1")
        try store.upsert(restored)
        let d = Deduplicator(store: store)
        guard case .duplicateContent(let match) = try d.decide(localIdentifier: "NEW-ID", sha256: "h1") else {
            Issue.record("expected duplicate"); return
        }
        #expect(try d.link(localIdentifier: "NEW-ID", to: match, existingAssetIsMissing: true))
        #expect(try store.item(localIdentifier: "NEW-ID")?.id == restored.id)
        #expect(try store.knownLocalIdentifiers().contains("NEW-ID"))
    }

    @Test func duplicateAssetOnSameDeviceBecomesAlias() throws {
        let store = try LibraryStore(url: nil)
        let original = item("A", sha: "h1")
        try store.upsert(original)
        let d = Deduplicator(store: store)
        guard case .duplicateContent(let match) = try d.decide(localIdentifier: "B", sha256: "h1") else {
            Issue.record("expected duplicate"); return
        }
        #expect(try d.link(localIdentifier: "B", to: match, existingAssetIsMissing: false) == false)
        #expect(try store.item(id: original.id)?.localIdentifier == "A")
        #expect(try d.check(localIdentifier: "B")?.id == original.id)
        #expect(try store.allItems().count == 1)
    }

    @Test func failedItemsDoNotBlockReupload() throws {
        let store = try LibraryStore(url: nil)
        try store.upsert(item(nil, sha: "h1", status: .failed))
        #expect(try Deduplicator(store: store).decide(localIdentifier: "X", sha256: "h1") == .upload)
    }

    @Test func backedUpRequiresAllParts() {
        var live = MediaItem(localIdentifier: "L", sha256: "h", filename: "IMG.HEIC", kind: .livePhoto, creationDate: nil, fileSize: 1)
        let f = RemoteFile(messageId: 1, fileId: "f", fileUniqueId: "u", size: 1)
        live.setRemote(f, for: .original)
        live.setRemote(f, for: .thumbnail)
        #expect(!live.isFullyUploaded)
        live.setRemote(f, for: .pairedVideo)
        #expect(live.isFullyUploaded)
    }

    @Test func sizeClassesFollowBotAPILimits() {
        #expect(SizePolicy.classify(5 * 1024 * 1024) == .normal)
        #expect(SizePolicy.classify(20 * 1024 * 1024) == .normal)
        #expect(SizePolicy.classify(20 * 1024 * 1024 + 1) == .uploadOnly)
        #expect(SizePolicy.classify(50 * 1024 * 1024 + 1) == .tooLargeToUpload)
    }

    @Test func storePersistsAndCounts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try LibraryStore(url: url)
            try store.upsert([item("A", sha: "1"), item("B", sha: "2", status: .tooLarge), item(nil, sha: "3", status: .queued)])
            store.setMeta("k", "v")
        }
        let reopened = try LibraryStore(url: url)
        #expect(try reopened.counts() == [.backedUp: 1, .tooLarge: 1, .queued: 1])
        #expect(reopened.meta("k") == "v")
        let updated = try reopened.update(id: try reopened.item(localIdentifier: "A")!.id) { $0.status = .failed }
        #expect(updated?.status == .failed)
    }
}

@Suite struct RateLimitTests {
    final class FakeClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
    }

    @Test func spacesSendsOnePerInterval() async {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 1.0, now: { clock.now })
        #expect(await limiter.reserve() == 0)
        #expect(await limiter.reserve() == 1)
        #expect(await limiter.reserve() == 2)
        clock.now = clock.now.addingTimeInterval(10)
        #expect(await limiter.reserve() == 0)
        #expect(await limiter.reserve(count: 3) == [1, 2, 3])
    }

    @Test func penaltyBlocksUntilRetryAfter() async {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 1.0, now: { clock.now })
        _ = await limiter.reserve()
        await limiter.penalize(retryAfter: 30)
        #expect(await limiter.reserve() == 30)
        #expect(await limiter.reserve() == 31)
    }

    @Test func retryAfterIsHonoured() {
        let policy = BackoffPolicy()
        #expect(policy.decide(error: TelegramError.rateLimited(retryAfter: 17), attempt: 0) == .retry(after: 18))
        #expect(policy.decide(error: TelegramError.rateLimited(retryAfter: 3), attempt: 5) == .retry(after: 4))
    }

    @Test func exponentialBackoffGrowsAndCaps() {
        let policy = BackoffPolicy(baseDelay: 2, maxDelay: 60, maxAttempts: 10)
        #expect(policy.ceiling(forAttempt: 0) == 2)
        #expect(policy.ceiling(forAttempt: 1) == 4)
        #expect(policy.ceiling(forAttempt: 3) == 16)
        #expect(policy.ceiling(forAttempt: 9) == 60)
        let err = TelegramError.network("offline")
        #expect(policy.decide(error: err, attempt: 3, jitter: { 1 }) == .retry(after: 16))
        #expect(policy.decide(error: err, attempt: 3, jitter: { 0 }) == .retry(after: 8))
    }

    @Test func permanentErrorsAndExhaustionGiveUp() {
        let policy = BackoffPolicy(maxAttempts: 3)
        #expect(policy.decide(error: TelegramError.api(code: 400, description: "bad"), attempt: 0) == .giveUp)
        #expect(policy.decide(error: TelegramError.api(code: 401, description: "Unauthorized"), attempt: 0) == .giveUp)
        #expect(policy.decide(error: TelegramError.http(status: 502), attempt: 3) == .giveUp)
        if case .retry = policy.decide(error: TelegramError.http(status: 502), attempt: 2) {} else { Issue.record("should retry") }
        if case .retry = policy.decide(error: URLError(.timedOut), attempt: 0) {} else { Issue.record("should retry URLError") }
    }
}

@Suite struct CacheEvictionTests {
    final class FakeClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
        func tick() -> Date { now = now.addingTimeInterval(1); return now }
    }

    func makeCache(capacity: Int64, clock: FakeClock) -> LRUDiskCache {
        LRUDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                     capacity: capacity, now: { clock.tick() })
    }

    @Test func evictsLeastRecentlyUsedFirst() throws {
        let clock = FakeClock()
        let cache = makeCache(capacity: 300, clock: clock)
        defer { cache.clear() }
        try cache.store(data: Data(count: 100), for: "a", ext: "jpg")
        try cache.store(data: Data(count: 100), for: "b", ext: "jpg")
        try cache.store(data: Data(count: 100), for: "c", ext: "jpg")
        #expect(cache.url(for: "a") != nil) // touch a → b is now oldest
        try cache.store(data: Data(count: 100), for: "d", ext: "jpg")
        #expect(cache.contains("a"))
        #expect(!cache.contains("b"))
        #expect(cache.contains("c") && cache.contains("d"))
        #expect(cache.totalSize == 300)
    }

    @Test func newestEntrySurvivesEvenIfLargerThanCap() throws {
        let clock = FakeClock()
        let cache = makeCache(capacity: 100, clock: clock)
        defer { cache.clear() }
        try cache.store(data: Data(count: 50), for: "small")
        try cache.store(data: Data(count: 500), for: "big", ext: "mov")
        #expect(!cache.contains("small"))
        #expect(cache.url(for: "big")?.pathExtension == "mov")
    }

    @Test func shrinkingCapacityEvictsAndClearEmpties() throws {
        let clock = FakeClock()
        let cache = makeCache(capacity: 1000, clock: clock)
        for k in ["1", "2", "3", "4"] { try cache.store(data: Data(count: 200), for: k) }
        #expect(cache.totalSize == 800)
        cache.setCapacity(450)
        #expect(cache.totalSize == 400)
        #expect(cache.contains("3") && cache.contains("4"))
        cache.clear()
        #expect(cache.totalSize == 0 && cache.count == 0)
    }

    @Test func manifestSurvivesReopen() throws {
        let clock = FakeClock()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = LRUDiskCache(directory: dir, capacity: 1000, now: { clock.tick() })
        try cache.store(data: Data(count: 10), for: "x")
        let reopened = LRUDiskCache(directory: dir, capacity: 1000)
        #expect(reopened.contains("x"))
        #expect(reopened.totalSize == 10)
        reopened.clear()
    }
}

@Suite struct ItemIdCaseTests {
    func item(id: String, local: String?, status: ItemStatus) -> MediaItem {
        MediaItem(id: id, localIdentifier: local, sha256: "h", filename: "a.jpg", kind: .photo, creationDate: Date(), fileSize: 10, status: status)
    }

    @Test func newIdsMatchCaptionIds() {
        let id = MediaItem(localIdentifier: "A", sha256: "", filename: "a.jpg", kind: .photo, creationDate: nil, fileSize: 0).id
        #expect(id == CaptionMeta(id: id, role: .original, kind: .photo, sha256: "", name: "a.jpg", size: 0).id)
    }

    @Test func uppercaseItemFoldsIntoScannedTwin() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idcase-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let upper = "BFBC0639-C389-4DAD-91ED-D734484D6B7E"
        do {
            let store = try LibraryStore(url: url)
            try store.upsert(item(id: upper, local: "PHONE/L0/001", status: .failed))
            try store.upsert(item(id: upper.lowercased(), local: nil, status: .backedUp))
            try store.upsert(item(id: "AAAAAAAA-0000-0000-0000-000000000001", local: "PHONE/L0/002", status: .queued))
        }
        let store = try LibraryStore(url: url)
        let all = try store.allItems()
        #expect(all.count == 2)
        let twin = try #require(try store.item(id: upper.lowercased()))
        #expect(twin.status == .backedUp)
        #expect(twin.localIdentifier == "PHONE/L0/001")
        #expect(try store.item(id: "aaaaaaaa-0000-0000-0000-000000000001")?.status == .queued)
        #expect(try store.items(status: .failed).isEmpty)
    }
}

@Suite struct RestoreLinkerTests {
    let date = Date(timeIntervalSince1970: 1_790_000_000)

    func cloud(_ name: String, at t: Date?, _ w: Int = 4032, _ h: Int = 3024, source: String? = nil) -> MediaItem {
        var i = MediaItem(localIdentifier: nil, sha256: "h", filename: name, kind: .photo, creationDate: t,
                          pixelWidth: w, pixelHeight: h, fileSize: 1, status: .backedUp)
        i.sourceLocalIdentifier = source
        return i
    }

    @Test func linksByUploadedAssetIdFirst() {
        let item = cloud("IMG_1.HEIC", at: date, source: "A/L0/001")
        // Renamed/edited on the phone since: only the id still matches.
        let assets = [AssetKey(localIdentifier: "A/L0/001", filename: "IMG_1 (edited).HEIC", creationDate: date, pixelWidth: 100, pixelHeight: 100)]
        #expect(RestoreLinker.match(unlinked: [item], assets: assets) == [item.id: "A/L0/001"])
    }

    @Test func fallsBackToNameSecondAndSize() {
        let item = cloud("IMG_2.HEIC", at: date)
        let assets = [
            AssetKey(localIdentifier: "B", filename: "img_2.heic", creationDate: date.addingTimeInterval(0.4), pixelWidth: 4032, pixelHeight: 3024),
            AssetKey(localIdentifier: "C", filename: "IMG_2.HEIC", creationDate: date.addingTimeInterval(1), pixelWidth: 4032, pixelHeight: 3024)
        ]
        #expect(RestoreLinker.match(unlinked: [item], assets: assets) == [item.id: "B"])
    }

    @Test func differentSizeOrMissingDateDoesNotMatch() {
        let a = cloud("IMG_3.HEIC", at: date)
        let b = cloud("IMG_4.HEIC", at: nil)
        let assets = [
            AssetKey(localIdentifier: "D", filename: "IMG_3.HEIC", creationDate: date, pixelWidth: 3024, pixelHeight: 4032),
            AssetKey(localIdentifier: "E", filename: "IMG_4.HEIC", creationDate: nil, pixelWidth: 4032, pixelHeight: 3024)
        ]
        #expect(RestoreLinker.match(unlinked: [a, b], assets: assets).isEmpty)
    }

    @Test func eachAssetLinksOnce() {
        let a = cloud("IMG_5.HEIC", at: date)
        let b = cloud("IMG_5.HEIC", at: date)
        let assets = [AssetKey(localIdentifier: "F", filename: "IMG_5.HEIC", creationDate: date, pixelWidth: 4032, pixelHeight: 3024)]
        let links = RestoreLinker.match(unlinked: [a, b], assets: assets)
        #expect(links.count == 1)
        #expect(Set(links.values) == ["F"])
    }

    /// Looking up file names only for photos the prefilter passes links exactly the same pairs as knowing every name,
    /// with name collisions, same-second bursts and photos linked by id.
    @Test func prefilterLinksTheSamePairs() {
        let items = [
            cloud("IMG_1.HEIC", at: date, source: "A"),
            cloud("IMG_2.HEIC", at: date),
            cloud("IMG_2.HEIC", at: date.addingTimeInterval(5)),
            cloud("IMG_3.HEIC", at: date, 3024, 4032),
            cloud("IMG_4.HEIC", at: nil),
        ]
        let all = [
            AssetKey(localIdentifier: "A", filename: "renamed.HEIC", creationDate: date, pixelWidth: 1, pixelHeight: 1),
            AssetKey(localIdentifier: "B1", filename: "IMG_2.HEIC", creationDate: date, pixelWidth: 4032, pixelHeight: 3024),
            AssetKey(localIdentifier: "B2", filename: "IMG_9.HEIC", creationDate: date, pixelWidth: 4032, pixelHeight: 3024),
            AssetKey(localIdentifier: "C", filename: "IMG_2.HEIC", creationDate: date.addingTimeInterval(5.7), pixelWidth: 4032, pixelHeight: 3024),
            AssetKey(localIdentifier: "D", filename: "IMG_3.HEIC", creationDate: date, pixelWidth: 4032, pixelHeight: 3024),
            AssetKey(localIdentifier: "E", filename: "IMG_3.HEIC", creationDate: date, pixelWidth: 3024, pixelHeight: 4032),
            AssetKey(localIdentifier: "F", filename: "IMG_4.HEIC", creationDate: nil, pixelWidth: 4032, pixelHeight: 3024),
            AssetKey(localIdentifier: "G", filename: "IMG_7.HEIC", creationDate: date.addingTimeInterval(99), pixelWidth: 10, pixelHeight: 10),
        ]
        let filter = RestoreLinker.Prefilter(unlinked: items)
        var lookedUp: [String] = []
        let filtered: [AssetKey] = all.compactMap { a in
            if filter.linksById(a.localIdentifier) {
                return AssetKey(localIdentifier: a.localIdentifier, filename: "", creationDate: a.creationDate, pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight)
            }
            guard filter.needsFilename(creationDate: a.creationDate, pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight) else { return nil }
            lookedUp.append(a.localIdentifier)
            return a
        }
        #expect(RestoreLinker.match(unlinked: items, assets: filtered) == RestoreLinker.match(unlinked: items, assets: all))
        #expect(RestoreLinker.match(unlinked: items, assets: all).count == 4)
        #expect(Set(lookedUp) == ["B1", "B2", "C", "D", "E"])
    }

    @Test func captionCarriesTheAssetId() throws {
        var m = CaptionMeta(id: UUID().uuidString, role: .original, kind: .photo, sha256: String(repeating: "a", count: 64), name: "x.jpg", size: 1)
        m.l = "A/L0/001"
        let decoded = try CaptionCodec.decode(try CaptionCodec.encode(m))
        #expect(decoded.l == "A/L0/001")
    }
}

@Suite struct CloudTrashTests {
    func backedUp() -> MediaItem {
        var item = MediaItem(localIdentifier: "A", sha256: "h", filename: "IMG_1.HEIC", kind: .photo, creationDate: nil, fileSize: 10, status: .backedUp)
        item.setParts([RemoteFile(messageId: 1, fileId: "f", fileUniqueId: "u", size: 10)], role: "o", expected: 1)
        return item
    }

    @Test func trashKeepsMessagesAndStopsCountingAsBackedUp() {
        var item = backedUp()
        let now = Date(timeIntervalSince1970: 1_000_000)
        CloudTrash.trash(&item, now: now)
        #expect(item.status == .trashed)
        #expect(item.trashedAt == now)
        #expect(item.allMessageIds == [1])
        #expect(!item.isViewableFromCloud)
        #expect(CloudTrash.daysLeft(item, now: now) == 30)
    }

    @Test func onlyBackedUpItemsCanBeTrashed() {
        var item = backedUp()
        item.status = .uploading
        CloudTrash.trash(&item)
        #expect(item.status == .uploading)
        #expect(item.trashedAt == nil)
    }

    @Test func expiresAfterThirtyDays() {
        var item = backedUp()
        let now = Date(timeIntervalSince1970: 1_000_000)
        CloudTrash.trash(&item, now: now)
        #expect(!CloudTrash.isExpired(item, now: now.addingTimeInterval(29 * 86400)))
        #expect(CloudTrash.daysLeft(item, now: now.addingTimeInterval(60)) == 30)
        #expect(CloudTrash.daysLeft(item, now: now.addingTimeInterval(29.5 * 86400)) == 1)
        #expect(CloudTrash.daysLeft(item, now: now.addingTimeInterval(31 * 86400)) == 0)
        #expect(CloudTrash.isExpired(item, now: now.addingTimeInterval(30 * 86400)))
    }

    @Test func missingDateNeverExpires() {
        var item = backedUp()
        item.status = .trashed
        #expect(!CloudTrash.isExpired(item, now: .distantFuture))
    }

    @Test func recoverRestoresBackedUp() {
        var item = backedUp()
        CloudTrash.trash(&item)
        CloudTrash.recover(&item)
        #expect(item.status == .backedUp)
        #expect(item.trashedAt == nil)
    }

    @Test func trashedStatusSurvivesEncoding() throws {
        var item = backedUp()
        CloudTrash.trash(&item, now: Date(timeIntervalSince1970: 5))
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.status == .trashed)
        #expect(decoded.trashedAt == Date(timeIntervalSince1970: 5))
    }
}

@Suite struct HashReuseTests {
    let date = Date(timeIntervalSince1970: 1_790_000_000)

    func tried(edited: Bool = false) -> MediaItem {
        var item = MediaItem(localIdentifier: "A", sha256: "h", filename: "IMG_1.MOV", kind: .video, creationDate: date, fileSize: 3_000, status: .queued)
        item.assetModifiedAt = date
        item.roleHashes = ["o": "h"]
        if edited {
            item.editedSize = 2_000
            item.roleHashes?["e"] = "e"
        }
        return item
    }

    @Test func unchangedPhotoReusesItsHashes() {
        #expect(Deduplicator.canReuseHashes(of: tried(), modified: date, sizes: (3_000, nil, nil)))
        #expect(Deduplicator.canReuseHashes(of: tried(edited: true), modified: date, sizes: (3_000, nil, 2_000)))
    }

    @Test func anyChangeHashesAgain() {
        #expect(!Deduplicator.canReuseHashes(of: tried(), modified: date.addingTimeInterval(1), sizes: (3_000, nil, nil)))
        #expect(!Deduplicator.canReuseHashes(of: tried(), modified: nil, sizes: (3_000, nil, nil)))
        #expect(!Deduplicator.canReuseHashes(of: tried(), modified: date, sizes: (3_001, nil, nil)))
        // Edited since the last try: an edit appeared that has no stored hash.
        #expect(!Deduplicator.canReuseHashes(of: tried(), modified: date, sizes: (3_000, nil, 2_000)))
        var never = tried()
        never.sha256 = ""
        #expect(!Deduplicator.canReuseHashes(of: never, modified: date, sizes: (3_000, nil, nil)))
        var noDate = tried()
        noDate.assetModifiedAt = nil
        #expect(!Deduplicator.canReuseHashes(of: noDate, modified: nil, sizes: (3_000, nil, nil)))
    }
}
