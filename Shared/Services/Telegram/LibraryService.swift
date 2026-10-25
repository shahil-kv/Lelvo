import Foundation
import CryptoKit
import TDLibKit
import MemvoCore

enum LibraryError: LocalizedError {
    case noLibrary
    case notALibrary
    case locked
    case wrongPassphrase

    var errorDescription: String? {
        switch self {
        case .noLibrary: return "Choose or create your Memvo library first."
        case .notALibrary: return "That channel isn't a Memvo library. Pick another channel or create a new library."
        case .locked: return "This library is end-to-end encrypted. Enter your passphrase to unlock it."
        case .wrongPassphrase: return "Wrong passphrase for this library."
        }
    }
}

/// The user's library channel: creating or choosing it, its header and E2E keys, and rebuilding the
/// local index by scanning channel history (the channel is the source of truth).
final class LibraryService: @unchecked Sendable {
    /// Message id → the document thumbnail's remote file id, learned while scanning (saves a message lookup per tile).
    let thumbnails = ThumbnailIdStore()

    static let titleDefault = "Memvo Library"
    private static let chatIdKey = "libraryChatId"
    private static let headerKey = "libraryHeader"
    private static let lastScanKey = "libraryLastScannedMessageId"
    private static let duplicatesKey = "libraryDuplicateMessageIds"
    private static let repairedKey = "fastVersionScanRepaired"

    /// Extra copies of already-stored parts found by the last full scan (safe to delete; the first copy stays).
    var duplicateMessageIds: [Int64] {
        ((UserDefaults.standard.array(forKey: Self.duplicatesKey) as? [NSNumber]) ?? []).map(\.int64Value)
    }

    private let td: TDService
    private let store: LibraryStore
    private let lock = NSLock()
    private var cachedKeys: E2EKeys?

    init(td: TDService, store: LibraryStore) {
        self.td = td
        self.store = store
    }

    // MARK: - State

    var chatId: Int64? {
        let v = UserDefaults.standard.object(forKey: Self.chatIdKey) as? NSNumber
        return v?.int64Value
    }

    var header: LibraryHeader? {
        UserDefaults.standard.string(forKey: Self.headerKey).flatMap { LibraryHeader.parse($0) }
    }

    var isConfigured: Bool { chatId != nil && header != nil }
    var isEncrypted: Bool { header?.encrypted == true }
    var isUnlocked: Bool { !isEncrypted || keys != nil }

    /// E2E keys from the Keychain (nil for plain libraries or when locked).
    var keys: E2EKeys? {
        lock.lock(); defer { lock.unlock() }
        if let cachedKeys { return cachedKeys }
        guard let raw = KeychainStore.data(for: .e2eMasterKey), raw.count == 32 else { return nil }
        cachedKeys = E2EKeys(master: SymmetricKey(data: raw))
        return cachedKeys
    }

    var captionKey: SymmetricKey? { isEncrypted ? keys?.captionKey : nil }

    private func save(chatId: Int64, header: LibraryHeader) {
        UserDefaults.standard.set(NSNumber(value: chatId), forKey: Self.chatIdKey)
        UserDefaults.standard.set(header.line, forKey: Self.headerKey)
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.chatIdKey)
        UserDefaults.standard.removeObject(forKey: Self.headerKey)
        UserDefaults.standard.removeObject(forKey: Self.lastScanKey)
        UserDefaults.standard.removeObject(forKey: Self.duplicatesKey) // ids of the old library's channel
        KeychainStore.set(nil as Data?, for: .e2eMasterKey)
        lock.withLock { cachedKeys = nil }
    }

    // MARK: - Choosing / creating

    struct ChannelChoice: Identifiable, Hashable {
        let id: Int64
        let title: String
        let isLibrary: Bool
        var encrypted = false
    }

    /// The library channel's current name in Telegram.
    func title() async -> String {
        guard let chatId, let chat = try? await td.chat(chatId) else { return Self.titleDefault }
        return chat.title
    }

    /// Renames the channel. Libraries are recognised by their header, never by name, so this is safe.
    func rename(_ title: String) async throws {
        guard let chatId else { throw LibraryError.noLibrary }
        try await rename(chatId: chatId, to: title)
    }

    func rename(chatId: Int64, to title: String) async throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do { _ = try await td.api().setChatTitle(chatId: chatId, title: String(clean.prefix(128))) } catch { throw error.asTD }
        appLog("Renamed library channel")
    }

    /// Channels the user owns or administers, marking ones that already hold a Memvo header.
    func candidateChannels() async throws -> [ChannelChoice] {
        let api = try td.api()
        _ = try? await api.loadChats(chatList: .chatListMain, limit: 500)
        let chats: Chats
        do { chats = try await api.getChats(chatList: .chatListMain, limit: 500) } catch { throw error.asTD }
        var out: [ChannelChoice] = []
        for id in chats.chatIds {
            guard let chat = try? await td.chat(id), case .chatTypeSupergroup(let sg) = chat.type, sg.isChannel,
                  let group = try? await api.getSupergroup(supergroupId: sg.supergroupId) else { continue }
            switch group.status {
            case .chatMemberStatusCreator, .chatMemberStatusAdministrator: break
            default: continue
            }
            let header = await readHeader(chatId: id)
            out.append(ChannelChoice(id: id, title: chat.title, isLibrary: header != nil, encrypted: header?.encrypted == true))
        }
        return out.sorted { ($0.isLibrary ? 0 : 1, $0.title) < ($1.isLibrary ? 0 : 1, $1.title) }
    }

    /// Creates a private channel with the format-1 header (pinned message + description).
    @discardableResult
    func createLibrary(title: String = titleDefault, passphrase: String?) async throws -> Int64 {
        let api = try td.api()
        let header: LibraryHeader
        var keys: E2EKeys?
        if let passphrase {
            (header, keys) = try LibraryHeader.newEncrypted(passphrase: passphrase)
        } else {
            header = .plain
        }
        let chat: Chat
        do {
            chat = try await api.createNewSupergroupChat(description: "Memvo Library · do not edit\n" + header.line,
                                                         forImport: false, isChannel: true, isForum: false, location: nil,
                                                         messageAutoDeleteTime: 0, title: title)
        } catch { throw error.asTD }
        let headerMessage = try await td.sendText(chatId: chat.id, text: header.messageText)
        do {
            _ = try await api.pinChatMessage(chatId: chat.id, disableNotification: true, messageId: headerMessage.id, onlyForSelf: false)
        } catch {
            AppLog.shared.warn("Pinning the library header failed: \(error.asTD.localizedDescription)")
        }
        if let keys { storeKeys(keys) }
        save(chatId: chat.id, header: header)
        appLog("Created library channel (\(header.encrypted ? "E2E" : "plain"))")
        return chat.id
    }

    /// Reads the header of an existing channel (pinned header message first, then the description).
    func readHeader(chatId: Int64) async -> LibraryHeader? {
        guard let api = try? td.api() else { return nil }
        await td.ensureChat(chatId)
        if let pinned = try? await api.getChatPinnedMessage(chatId: chatId),
           case .messageText(let t) = pinned.content, let h = LibraryHeader.parse(t.text.text) {
            return h
        }
        if let chat = try? await td.chat(chatId), case .chatTypeSupergroup(let sg) = chat.type,
           let info = try? await api.getSupergroupFullInfo(supergroupId: sg.supergroupId) {
            return LibraryHeader.parse(info.description)
        }
        return nil
    }

    /// Uses an existing channel. Channels without a header are turned into a plain library (header added).
    func useExisting(chatId: Int64) async throws -> LibraryHeader {
        if let header = await readHeader(chatId: chatId) {
            save(chatId: chatId, header: header)
            if header.encrypted { KeychainStore.set(nil as Data?, for: .e2eMasterKey); lock.withLock { cachedKeys = nil } }
            return header
        }
        let message = try await td.sendText(chatId: chatId, text: LibraryHeader.plain.messageText)
        _ = try? await td.api().pinChatMessage(chatId: chatId, disableNotification: true, messageId: message.id, onlyForSelf: false)
        save(chatId: chatId, header: .plain)
        return .plain
    }

    func unlock(passphrase: String) throws {
        guard let header, header.encrypted else { return }
        guard let keys = try header.unlock(passphrase: passphrase) else { throw LibraryError.wrongPassphrase }
        storeKeys(keys)
    }

    private func storeKeys(_ keys: E2EKeys) {
        KeychainStore.set(keys.masterData, for: .e2eMasterKey)
        lock.withLock { cachedKeys = keys }
    }

    // MARK: - Scanning

    struct ScanSummary {
        var messages = 0
        var items = 0
        var incomplete = 0
        var orphans: [Int64] = []
        var unreadable = 0
    }

    /// Reads every Memvo document in the channel and rebuilds the local index.
    /// The one-time full scan that repairs items from test builds hasn't run yet (see `scan`).
    var needsRepairScan: Bool { isConfigured && store.meta(Self.repairedKey) == nil }

    /// `full == false` only reads messages newer than the last scan (cheap; used before resuming uploads).
    @discardableResult
    func scan(full requestedFull: Bool, progress: ((Int) -> Void)? = nil) async throws -> ScanSummary {
        guard let chatId else { throw LibraryError.noLibrary }
        // Recent scans in test builds before this fix could copy a fast version's name, size and hash onto its item;
        // one full scan rebuilds every item from its own captions.
        let full = requestedFull || store.meta(Self.repairedKey) == nil
        guard isUnlocked else { throw LibraryError.locked }
        let api = try td.api()
        await td.ensureChat(chatId)
        let stopAt: Int64 = full ? 0 : Int64(UserDefaults.standard.integer(forKey: Self.lastScanKey))
        var summary = ScanSummary()
        var cloud: [CloudMessage] = []
        var thumbnailIds: [Int64: String] = [:]
        var from: Int64 = 0
        var newest: Int64 = 0
        scanLoop: while true {
            let page: FoundChatMessages
            do {
                page = try await api.searchChatMessages(chatId: chatId, filter: .searchMessagesFilterDocument, fromMessageId: from,
                                                       limit: 100, offset: 0, query: "", senderId: nil, topicId: nil)
            } catch {
                let mapped = error.asTD
                if case .floodWait(let s)? = (mapped as? TDServiceError)?.kind {
                    try await Task.sleep(nanoseconds: UInt64(s) * 1_000_000_000)
                    continue
                }
                throw mapped
            }
            for message in page.messages {
                newest = max(newest, message.id)
                if message.id <= stopAt { break scanLoop }
                summary.messages += 1
                guard case .messageDocument(let doc) = message.content else { continue }
                let caption = doc.caption.text
                guard CaptionCodec.isMemvo(caption) else { continue }
                do {
                    let meta = try CaptionCodec.decode(caption, captionKey: captionKey)
                    let file = doc.document.document
                    if let thumb = doc.document.thumbnail?.file.remote.id, !thumb.isEmpty { thumbnailIds[message.id] = thumb }
                    cloud.append(CloudMessage(messageId: message.id, meta: meta, fileId: file.remote.id,
                                              uniqueId: file.remote.uniqueId, size: file.size))
                } catch {
                    summary.unreadable += 1
                }
            }
            progress?(summary.messages)
            guard page.nextFromMessageId != 0, !page.messages.isEmpty else { break }
            from = page.nextFromMessageId
        }

        thumbnails.record(thumbnailIds, chatId: chatId)
        try merge(cloud: cloud, full: full, summary: &summary)
        if full { UserDefaults.standard.set(summary.orphans.map { NSNumber(value: $0) }, forKey: Self.duplicatesKey) }
        if newest > 0 { UserDefaults.standard.set(Int(newest), forKey: Self.lastScanKey) }
        if full { store.setMeta(Self.repairedKey, "1") }
        appLog("Library scan (\(full ? "full" : "recent")): \(summary.messages) messages, \(summary.items) items, \(summary.incomplete) incomplete, \(summary.orphans.count) duplicates")
        return summary
    }

    /// Merges scanned items into the store, keeping local links (asset identifiers) and pending work.
    private func merge(cloud: [CloudMessage], full: Bool, summary: inout ScanSummary) throws {
        // A partial scan only sees new messages; combine them with the parts already known.
        var messages = cloud
        if !full {
            let ids = Set(cloud.map(\.meta.id))
            let scanned = Set(cloud.map(\.messageId))
            for item in try store.allItems() where ids.contains(item.id) {
                messages += LibraryIndexer.knownMessages(of: item, excluding: scanned)
            }
        }
        let result = LibraryIndexer.build(messages)
        summary.items = result.items.count
        summary.incomplete = result.items.filter { $0.status != .backedUp }.count
        summary.orphans = result.orphanMessageIds

        var merged: [MediaItem] = []
        let existing = Dictionary(uniqueKeysWithValues: try store.allItems().map { ($0.id, $0) })
        for var item in result.items {
            if let local = existing[item.id] {
                item.localIdentifier = local.localIdentifier
                item.verifiedAt = local.verifiedAt
                item.chosen = local.chosen
                item.streamingCopySkipped = local.streamingCopySkipped
                if local.status == .trashed, item.status == .backedUp {
                    // In Recently Deleted on this device: the messages are still there on purpose.
                    item.status = .trashed
                    item.trashedAt = local.trashedAt
                }
                if item.status != .backedUp, local.status == .uploading || local.status == .queued {
                    // Still being uploaded by this device: keep the queue state, update known parts.
                    item.status = local.status
                    item.lastError = local.lastError
                }
            }
            merged.append(item)
        }
        if full {
            // Items that vanished from the channel: keep phone-linked ones as failed so they re-upload.
            let seen = Set(result.items.map(\.id))
            // Deleted elsewhere while in Recently Deleted here: nothing left to recover.
            for item in existing.values where !seen.contains(item.id) && item.status == .trashed { try store.delete(id: item.id) }
            for item in existing.values where !seen.contains(item.id) && item.cloudParts != nil && item.status == .backedUp {
                if item.localIdentifier != nil {
                    var missing = item
                    missing.status = .failed
                    missing.cloudParts = nil
                    missing.lastError = "Not found in the Telegram channel any more. Tap Retry to upload it again."
                    merged.append(missing)
                } else {
                    try store.delete(id: item.id)
                }
            }
        }
        try store.upsert(merged)
    }

    /// Deletes the extra copies found by the last full scan.
    func removeDuplicateMessages() async throws {
        try await deleteOrphans(duplicateMessageIds)
        UserDefaults.standard.removeObject(forKey: Self.duplicatesKey)
        appLog("Removed duplicate messages from the library channel")
    }

    /// Deletes duplicate messages reported by a scan.
    func deleteOrphans(_ ids: [Int64]) async throws {
        guard let chatId else { return }
        for batch in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            try await td.deleteMessages(chatId: chatId, ids: batch)
        }
    }
}

/// Remembers each document's thumbnail remote id per library, on disk, so grid thumbnails download directly.
final class ThumbnailIdStore: @unchecked Sendable {
    private let lock = NSLock()
    private var chatId: Int64?
    private var ids: [Int64: String] = [:]

    private func url(_ chatId: Int64) -> URL {
        AppPaths.caches.appendingPathComponent("thumbnail-ids-\(chatId).json")
    }

    func record(_ found: [Int64: String], chatId: Int64) {
        guard !found.isEmpty else { return }
        let snapshot: [Int64: String] = lock.withLock {
            load(chatId)
            ids.merge(found) { $1 }
            return ids
        }
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url(chatId), options: .atomic) }
    }

    func remoteId(messageId: Int64, chatId: Int64) -> String? {
        lock.withLock {
            load(chatId)
            return ids[messageId]
        }
    }

    /// Caller holds the lock.
    private func load(_ chatId: Int64) {
        guard self.chatId != chatId else { return }
        self.chatId = chatId
        ids = (try? Data(contentsOf: url(chatId))).flatMap { try? JSONDecoder().decode([Int64: String].self, from: $0) } ?? [:]
    }
}
