import Foundation
import Testing
import CloudGalleryCore

@Suite struct DedupeTests {
    func item(_ local: String?, sha: String, status: ItemStatus = .backedUp) -> LibraryItem {
        LibraryItem(localIdentifier: local, sha256: sha, filename: "a.jpg", kind: .photo, creationDate: Date(), fileSize: 10, status: status)
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
        var live = LibraryItem(localIdentifier: "L", sha256: "h", filename: "IMG.HEIC", kind: .livePhoto, creationDate: nil, fileSize: 1)
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
