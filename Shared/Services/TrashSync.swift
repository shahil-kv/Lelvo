import Foundation
import LelvoCore

/// Sends Recently Deleted changes to the channel as notes (docs/CLOUD_FORMAT.md §7.2). Changes wait in the index, so they
/// survive the app closing. A burst shares one note and at most one goes a minute, so deleting photos one by one stays
/// light for Telegram.
final class TrashSync: @unchecked Sendable {
    static let shared = TrashSync()

    /// On from the first release with notes: there were no installs to update first. An app older than this ignores notes,
    /// so it can still offer a deleted photo for Free Up Space. Off, Recently Deleted works per device.
    static let sendsNotes = true

    private let lock = NSLock()
    private let gate = AsyncGate()
    private var lastSent: Date?
    private var scheduled = false
    private var lastOpenCheck: Date?
    private var opening = false
    private var removingNotes = false

    private var env: AppEnvironment { AppEnvironment.shared }

    /// The library to queue notes for, nil when none are sent. Passed to `LibraryStore.changeTrashState`, which records a
    /// change and its note together.
    var noteChatId: Int64? {
        guard Self.sendsNotes, !DemoMode.isActive else { return nil }
        return env.library.chatId
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

    /// Sends everything waiting, one note per kind of change, honouring `FLOOD_WAIT` exactly. Whatever fails stays queued
    /// and is tried again a minute later. Also called when the app goes to the background, without waiting for the minute.
    func send() async {
        guard !DemoMode.isActive else { return }
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard env.isConfigured, env.library.isUnlocked, let chatId = env.library.chatId,
              let queued = try? env.store.queuedTrashChanges(chatId: chatId), !queued.isEmpty else { return }
        if queued[.gone] != nil { try? env.store.dropRetiredTrashChanges() }
        var failed = false
        for op in [TrashLog.Op.delete, .recover] {
            guard let ids = queued[op], !ids.isEmpty else { continue }
            do {
                try await env.engine.withNoteSlot { [env] in try await env.library.sendTrashNote(op, itemIds: ids, chatId: chatId) }
                lock.withLock { lastSent = Date() }
                try env.store.clearTrashChanges(op, itemIds: ids)
            } catch {
                AppLog.shared.warn("Recently Deleted note not sent, will try again: \(error.localizedDescription)")
                failed = true
            }
        }
        // Every device now uses the date Telegram put on the note, this one too.
        try? env.library.applyTrashNotes(messagesSeen: false)
        await removeFinishedNotes()
        // Something queued during the send, or a failure: the next try keeps to the one-minute pace.
        if failed { lock.withLock { lastSent = Date() } }
        if failed || (try? env.store.queuedTrashChanges(chatId: chatId).isEmpty) == false { schedule() }
    }

    /// Before leaving a library or signing out: give waiting changes a moment. A switch keeps what can't be sent with its
    /// library (`LibrarySnapshots.saveChoices`); after a sign out the photos stay normal backups on the other devices,
    /// which keeps data.
    func sendBeforeLeaving() async {
        _ = try? await withDeadline(seconds: 5) { await TrashSync.shared.send() }
    }

    /// When the app opens: read what the other devices did, send what's waiting, and do the 30-day cleanup.
    func onOpen() async {
        guard !DemoMode.isActive else { await GalleryActions.emptyExpiredTrash(); return }
        guard env.isConfigured, env.library.isUnlocked else { return }
        // Focusing a Mac window counts as opening. While the app runs, live updates already bring every change.
        let minimumGap = min(5 * 60, CloudTrash.retention)
        // Also not while one is running: `lastOpenCheck` is only set once it has caught up.
        guard lock.withLock({
            guard !opening, lastOpenCheck.map({ Date().timeIntervalSince($0) >= minimumGap }) ?? true else { return false }
            opening = true
            return true
        }) else { return }
        defer { lock.withLock { opening = false } }
        guard (try? await env.td.waitUntilReady(timeout: 30)) != nil else { return }
        do { try await env.library.catchUp() } catch {
            AppLog.shared.warn("Couldn't check for changes from other devices: \(error.localizedDescription)")
            return
        }
        lock.withLock { lastOpenCheck = Date() }
        do { try await followTelegram() } catch {
            AppLog.shared.warn("Couldn't check Recently Deleted with Telegram: \(error.localizedDescription)")
            return
        }
        await send()
        await removeFinishedNotes()
        // The channel was just read, so favorites and albums can send, tidy up and compact safely.
        await MetaSync.shared.onOpen()
        await GalleryActions.emptyExpiredTrash()
    }

    /// Per library and not in the index, which a library switch clears: running this twice could put a photo the user
    /// recovered on another device back in Recently Deleted.
    private func addedOldItemsKey(_ chatId: Int64) -> String { "trashNotesForOldItemsAdded.\(chatId)" }

    /// Makes Recently Deleted match the channel. Only called right after catching up, so a note this device hasn't read
    /// can't be missed. Items from before notes existed get one, once. After that an item no note keeps here follows
    /// Telegram: messages gone means deleted for good, messages still there means recovered (or its note was removed in
    /// the Telegram app): either way, keeping the photo.
    func followTelegram() async throws {
        guard Self.sendsNotes, let chatId = env.library.chatId, !env.library.needsRepairScan else { return }
        // This order, as a send may finish meanwhile: an item's change is queued with it, and its note is stored before the
        // row goes. So each item read here is either in `waiting` or its note is in `notes`. The other way round, a photo
        // just deleted looked like one no note keeps, and came back.
        let trashed = try env.store.items(status: .trashed)
        let waiting = Set(try env.store.queuedTrashChanges(chatId: chatId).values.flatMap { $0 })
        var notes = try env.store.trashNotes()
        if !UserDefaults.standard.bool(forKey: addedOldItemsKey(chatId)) {
            let old = TrashLog.itemsNeedingANote(trashed: trashed, notes: notes, waiting: waiting)
            if !old.isEmpty {
                appLog("Adding \(old.count) items already in Recently Deleted to your other devices")
                try env.store.queueTrashChange(.delete, itemIds: old.map(\.id), chatId: chatId)
                schedule()
            }
            UserDefaults.standard.set(true, forKey: addedOldItemsKey(chatId))
            return
        }
        guard !trashed.isEmpty else { return }
        let toConfirm = TrashLog.notesToConfirm(trashed: trashed, notes: notes, waiting: waiting)
        let stillThere = try await env.td.existingMessages(chatId: chatId, ids: Array(toConfirm))
        // Switched library while asking: the index below is the other library's now.
        guard env.library.chatId == chatId else { return }
        let removed = toConfirm.subtracting(stillThere)
        if !removed.isEmpty {
            try env.store.removeTrashNotes(messageIds: removed)
            notes.removeAll { removed.contains($0.messageId) }
        }
        let uncovered = TrashLog.uncovered(trashed: trashed, notes: notes, stillInChannel: Set(notes.map(\.messageId)), waiting: waiting)
        guard !uncovered.isEmpty else { return }
        let inChannel = try await env.td.existingMessages(chatId: chatId, ids: uncovered.flatMap(\.allMessageIds))
        guard env.library.chatId == chatId else { return }
        // The user may have acted during the wait for Telegram: their change is the newer one.
        let waitingNow = Set(try env.store.queuedTrashChanges(chatId: chatId).values.flatMap { $0 })
        var gone = 0, back = 0
        for item in uncovered where !waitingNow.contains(item.id) && !item.allMessageIds.isEmpty {
            if TrashLog.allMessagesGone(item, existing: inChannel) {
                try env.store.forgetDeletedItem(item)
                env.thumbnailCache.remove(CloudMediaService.thumbnailKey(item))
                gone += 1
            } else {
                let done = try TrashGate.shared.ifNotDeleting(item.id) { try env.store.update(id: item.id) { CloudTrash.recover(&$0) } }
                if done { back += 1 }
            }
        }
        appLog("Recently Deleted followed Telegram: \(gone) deleted for good, \(back) back in your library")
    }

    /// Another device finished with a note while this one is open.
    func followOtherDevice() async {
        guard env.isConfigured, env.library.isUnlocked, !DemoMode.isActive else { return }
        do {
            try await env.library.scan(full: false)
            try await followTelegram()
        } catch {
            AppLog.shared.warn("Couldn't follow another device's change: \(error.localizedDescription)")
        }
    }

    /// Deletes every note that has done its job, in batches, so nothing stays in the channel.
    func removeFinishedNotes() async {
        guard !DemoMode.isActive, env.library.isUnlocked, !env.library.needsRepairScan, let chatId = env.library.chatId,
              let notes = try? env.store.trashNotes(), !notes.isEmpty, let known = try? env.store.allItems() else { return }
        // One at a time, or the same notes would be deleted twice. What's left waits for the next call.
        guard lock.withLock({
            guard !removingNotes else { return false }
            removingNotes = true
            return true
        }) else { return }
        defer { lock.withLock { removingNotes = false } }
        let finished = TrashLog.notesToRemove(notes, known: known).map(\.messageId)
        for start in stride(from: 0, to: finished.count, by: CloudTrash.maxMessagesPerDelete) {
            let batch = Array(finished[start..<min(start + CloudTrash.maxMessagesPerDelete, finished.count)])
            if start > 0 { try? await Task.sleep(nanoseconds: UInt64(BackupEngine.uploadSpacing * 1_000_000_000)) }
            while true {
                do {
                    try await env.td.deleteMessages(chatId: chatId, ids: batch)
                    try? env.store.removeTrashNotes(messageIds: batch)
                    appLog("Removed \(batch.count) finished Recently Deleted notes")
                    break
                } catch {
                    guard case .floodWait(let seconds)? = (error as? TDServiceError)?.kind,
                          (try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)) != nil else {
                        AppLog.shared.warn("Recently Deleted notes not removed, will try again: \(error.localizedDescription)")
                        return
                    }
                }
            }
        }
    }
}
