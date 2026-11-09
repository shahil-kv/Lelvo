import Foundation
import LelvoCore

/// Sends favorite and album changes to the channel as notes (docs/CLOUD_FORMAT.md §7.3), so every device and every
/// save to Photos sees them. Changes wait in the index, so they survive the app closing. A burst shares one note per
/// action and album, and at most one send goes a minute, through the same slot and `FLOOD_WAIT` pause as uploads.
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
                if let key = MetaLog.Note(messageId: 0, date: Date(), op: body.op, ids: [], album: body.album).key {
                    try env.store.clearMetaChange(itemIds: body.ids, key: key, value: body.op == .favorite || body.op == .albumAdd)
                }
            } catch {
                AppLog.shared.warn("Favorites and albums note not sent, will try again: \(error.localizedDescription)")
                failed = true
                break
            }
        }
        try? env.library.applyMetaNotes()
        await removeFinishedNotes()
        if failed { lock.withLock { lastSent = Date() } }
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
        let finished = MetaLog.notesToRemove(notes).map(\.messageId)
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
        guard let chatId = env.library.chatId, let notes = try? env.store.metaNotes(), notes.count > MetaLog.compactAbove,
              (try? env.store.queuedMetaChanges(chatId: chatId).isEmpty) == true else { return }
        await gate.acquire()
        defer { Task { await gate.release() } }
        for body in MetaLog.compacted(notes) {
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
