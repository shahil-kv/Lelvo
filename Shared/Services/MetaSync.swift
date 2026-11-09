import Foundation
import LelvoCore

/// Sends favorite and album changes to the channel as notes (docs/CLOUD_FORMAT.md §7.3), so every device and every
/// save to Photos sees them. Changes wait in the index, so they survive the app closing. A burst shares one note per
/// action and album, and at most one send goes every 10 seconds, through the same slot and `FLOOD_WAIT` pause as uploads.
final class MetaSync: @unchecked Sendable {
    static let shared = MetaSync()

    private let lock = NSLock()
    private let gate = AsyncGate()
    private var lastSent: Date?
    private var scheduled = false
    private var cleaning = false

    private var env: AppEnvironment { AppEnvironment.shared }

    /// The library to queue notes for. Nil in the demo and before a library is chosen: the change stays on this device.
    var noteChatId: Int64? {
        guard !DemoMode.isActive else { return nil }
        return env.library.chatId
    }

    /// Sets the favorite or an album on items in the Telegram library and queues the note. Items without a finished
    /// backup aren't touched: their favorite and albums go with their backup.
    @discardableResult
    func change(_ items: [MediaItem], key: MetaLog.Key, value: Bool) throws -> Int {
        let ids = items.filter { $0.status == .backedUp || $0.status == .trashed }.map(\.id)
        guard !ids.isEmpty else { return 0 }
        let chatId = noteChatId
        try env.store.changeMeta(ids: ids, key: key, value: value, chatId: chatId)
        if chatId != nil { schedule() }
        return ids.count
    }

    func schedule() {
        let delay: TimeInterval? = lock.withLock {
            guard !scheduled else { return nil }
            scheduled = true
            return TrashLog.sendDelay(lastSent: lastSent, now: Date())
        }
        guard let delay else { return }
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            lock.withLock { scheduled = false }
            await send()
        }
    }

    /// Sends everything waiting. Whatever fails stays queued and is tried again a minute later.
    func send() async {
        guard !DemoMode.isActive else { return }
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard env.isConfigured, env.library.isUnlocked, let chatId = env.library.chatId,
              let queued = try? env.store.queuedMetaChanges(chatId: chatId), !queued.isEmpty else { return }
        var failed = false
        for body in MetaLog.bodies(for: queued) {
            do {
                try await env.engine.withNoteSlot { [env] in try await env.library.sendMetaNote(body, chatId: chatId) }
                lock.withLock { lastSent = Date() }
                if let key = body.key { try env.store.clearMetaChange(itemIds: body.ids, key: key, value: body.op.value) }
            } catch {
                AppLog.shared.warn("Favorites and albums note not sent, will try again: \(error.localizedDescription)")
                failed = true
                break
            }
        }
        // Only the items just sent: the rest already follow their notes.
        try? env.library.applyMetaNotes(only: Set(queued.keys))
        await removeFinishedNotes()
        if failed { lock.withLock { lastSent = TrashLog.lastSentAfterFailure(now: Date()) } }
        if failed || (try? env.store.queuedMetaChanges(chatId: chatId).isEmpty) == false { schedule() }
    }

    /// Before leaving a library or signing out: give waiting changes a moment.
    func sendBeforeLeaving() async {
        _ = try? await withDeadline(seconds: 5) { await MetaSync.shared.send() }
    }

    /// When the app opens, after the channel was read: send what's waiting and tidy up.
    func onOpen() async {
        guard !DemoMode.isActive, env.isConfigured, env.library.isUnlocked else { return }
        await send()
        await compactIfLong()
        await removeFinishedNotes()
    }

    /// Deletes notes that no longer decide anything, in batches, so the channel doesn't fill up.
    func removeFinishedNotes() async {
        guard !DemoMode.isActive, env.library.isUnlocked, !env.library.needsRepairScan, let chatId = env.library.chatId,
              let notes = try? env.store.metaNotes(), !notes.isEmpty else { return }
        guard lock.withLock({
            guard !cleaning else { return false }
            cleaning = true
            return true
        }) else { return }
        defer { lock.withLock { cleaning = false } }
        // The whole index only when a note is old enough for its items to have been deleted for good.
        let anyOld = notes.contains { Date().timeIntervalSince($0.date) > MetaLog.goneAfter }
        let known = anyOld ? Set(((try? env.store.allItems()) ?? []).map(\.id)) : []
        let finished = MetaLog.notesToRemove(notes, known: known.isEmpty ? nil : known).map(\.messageId)
        for start in stride(from: 0, to: finished.count, by: CloudTrash.maxMessagesPerDelete) {
            let batch = Array(finished[start..<min(start + CloudTrash.maxMessagesPerDelete, finished.count)])
            if start > 0 { try? await Task.sleep(nanoseconds: UInt64(BackupEngine.uploadSpacing * 1_000_000_000)) }
            while true {
                do {
                    try await env.td.deleteMessages(chatId: chatId, ids: batch)
                    try? env.store.removeMetaNotes(messageIds: batch)
                    appLog("Removed \(batch.count) finished favorites and albums notes")
                    break
                } catch {
                    guard case .floodWait(let seconds)? = (error as? TDServiceError)?.kind,
                          (try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)) != nil else {
                        AppLog.shared.warn("Favorites and albums notes not removed, will try again: \(error.localizedDescription)")
                        return
                    }
                }
            }
        }
    }

    /// With many notes left, sends the current state as fresh notes, which makes every older one removable. Only right
    /// after the channel was read (`onOpen`), so it can't override a note from another device it hasn't seen.
    private func compactIfLong() async {
        guard let chatId = env.library.chatId, (try? env.store.metaNotes().count).map({ $0 > MetaLog.compactAbove }) == true,
              (try? env.store.queuedMetaChanges(chatId: chatId).isEmpty) == true else { return }
        await gate.acquire()
        defer { Task { await gate.release() } }
        // Read the newest messages right before, so a change another device just sent is part of the state written.
        guard (try? await env.library.scan(full: false)) != nil, let notes = try? env.store.metaNotes(),
              let all = try? env.store.allItems(), !all.isEmpty else { return }
        let fresh = MetaLog.compacted(notes, known: Set(all.map(\.id)))
        // Only when it really shrinks the channel: a library with many albums can't get below the limit, and must not
        // rewrite everything on every open. Nor after skipping a note this version can't read, whose effect it would
        // overwrite.
        guard fresh.count * 2 < notes.count, !env.library.skippedMetaNotes else { return }
        for body in fresh {
            do {
                try await env.engine.withNoteSlot { [env] in try await env.library.sendMetaNote(body, chatId: chatId) }
            } catch {
                AppLog.shared.warn("Favorites and albums notes not compacted, will try again: \(error.localizedDescription)")
                return
            }
        }
        lock.withLock { lastSent = Date() }
        appLog("Compacted \(notes.count) favorites and albums notes")
    }
}
