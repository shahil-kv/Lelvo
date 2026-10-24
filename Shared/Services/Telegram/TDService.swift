import Foundation
import TDLibKit
import CloudGalleryCore

/// Errors surfaced to the UI from the Telegram layer.
enum TDServiceError: LocalizedError {
    case notReady
    case missingCredentials
    case telegram(code: Int, message: String)
    case sendFailed(String)
    case unexpectedContent
    case sizeMismatch(expected: Int64, actual: Int64)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notReady: return "Not connected to Telegram yet."
        case .missingCredentials: return "Enter your api_id and api_hash from my.telegram.org first."
        case .telegram(let code, let message): return TDServiceError.friendly(code: code, message: message)
        case .sendFailed(let m): return "Upload failed: \(m)"
        case .unexpectedContent: return "That message isn't a CloudGallery file."
        case .sizeMismatch(let e, let a): return "Telegram stored \(a) bytes but \(e) were uploaded."
        case .cancelled: return "Cancelled."
        }
    }

    static func friendly(code: Int, message: String) -> String {
        switch message {
        case let m where m.contains("PHONE_NUMBER_INVALID"): return "That phone number isn't valid. Use international format, e.g. +91 98765 43210."
        case let m where m.contains("PHONE_CODE_INVALID"): return "Wrong login code. Check the code Telegram sent you."
        case let m where m.contains("PHONE_CODE_EXPIRED"): return "The login code expired. Request a new one."
        case let m where m.contains("PASSWORD_HASH_INVALID"): return "Wrong two-step verification password."
        case let m where m.contains("API_ID_INVALID"): return "api_id / api_hash are invalid. Copy them again from my.telegram.org."
        case let m where m.contains("API_ID_PUBLISHED_FLOOD"): return "Telegram blocked this api_id. Create your own at my.telegram.org."
        case let m where m.contains("USER_RESTRICTED"):
            return "Telegram has limited this account, so it can't create channels. In Telegram, message @SpamBot to see why and appeal, or use a different Telegram account."
        case let m where m.contains("CHANNELS_TOO_MUCH"):
            return "This account is in too many channels and groups. Leave some in Telegram, or pick an existing channel below."
        case let m where m.contains("PHONE_NUMBER_BANNED"):
            return "Telegram has banned this phone number. Use a different Telegram account."
        case let m where m.contains("FROZEN"):
            return "Telegram has frozen this account: it can still read, but it can't upload. Your library stays where it is. Open the Telegram app to see the notice and appeal."
        case let m where m.contains("FLOOD_WAIT") || code == 429:
            let s = TelegramErrorClassifier.floodWaitSeconds(m) ?? 0
            return "Telegram asked us to slow down. Waiting \(s) s."
        default: return "Telegram error \(code): \(message)"
        }
    }

    /// Telegram refused the app's api_id (revoked, or blocked for being published).
    var keysRejected: Bool {
        guard case .telegram(_, let message) = self else { return false }
        return message.contains("API_ID_INVALID") || message.contains("API_ID_PUBLISHED_FLOOD")
    }

    /// Classification used by the backup job machine.
    var kind: TelegramErrorKind {
        switch self {
        case .telegram(let code, let message): return TelegramErrorClassifier.classify(code: code, message: message)
        case .sendFailed(let m): return TelegramErrorClassifier.classify(code: 400, message: m)
        case .notReady: return .transient
        case .missingCredentials: return .auth
        default: return .permanent
        }
    }
}

extension Swift.Error {
    /// Normalises TDLibKit errors into `TDServiceError`.
    var asTD: Swift.Error {
        if let e = self as? TDLibKit.Error { return TDServiceError.telegram(code: e.code, message: e.message) }
        return self
    }
}

/// Owns the single TDLib client: authorization, uploads that wait for server confirmation,
/// ranged downloads and history. UIKit-free so it can be compiled and reasoned about on its own.
final class TDService: @unchecked Sendable {
    static let shared = TDService()

    enum AuthStep: Equatable {
        case needsCredentials
        case starting
        case waitPhone
        /// `length` is the number of digits Telegram sent, or 0 when the code is a word or phrase.
        case waitCode(info: String, length: Int)
        case waitPassword(hint: String)
        case waitEmail
        case waitOtherDevice(link: String)
        case waitRegistration
        case ready
        case loggingOut
        case closed
    }

    private let manager = TDLibClientManager()
    private let lock = NSLock()
    private(set) var client: TDLibClient?
    private var _auth: AuthStep = .needsCredentials
    private var authObservers: [UUID: (AuthStep) -> Void] = [:]
    private var sendWaiters: [Int64: CheckedContinuation<Message, Swift.Error>] = [:]
    private var finishedSends: [Int64: Result<Message, Swift.Error>] = [:]
    private var uploadObservers: [Int: (Int64, Int64) -> Void] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    let databaseDirectory: URL
    let filesDirectory: URL

    private init() {
        let fm = FileManager.default
        let support = AppPaths.support
        let caches = AppPaths.caches
        databaseDirectory = support.appendingPathComponent("tdlib", isDirectory: true)
        filesDirectory = caches.appendingPathComponent("tdlib-files", isDirectory: true)
        try? fm.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        var db = databaseDirectory
        try? db.setResourceValues(noBackup)
    }

    // MARK: - Auth state

    var auth: AuthStep {
        lock.lock(); defer { lock.unlock() }
        return _auth
    }

    var isReady: Bool { auth == .ready }

    @discardableResult
    func observeAuth(_ handler: @escaping (AuthStep) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        authObservers[id] = handler
        let current = _auth
        lock.unlock()
        handler(current)
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock(); authObservers[id] = nil; lock.unlock()
    }

    private func setAuth(_ step: AuthStep) {
        lock.lock()
        _auth = step
        let observers = Array(authObservers.values)
        let waiters = step == .ready ? readyWaiters : []
        if step == .ready { readyWaiters.removeAll() }
        lock.unlock()
        observers.forEach { $0(step) }
        waiters.forEach { $0.resume() }
    }

    /// Waits until authorised (or returns immediately if already ready). Throws after `timeout`.
    func waitUntilReady(timeout: TimeInterval = 30) async throws {
        if isReady { return }
        guard TDCredentials.load() != nil else { throw TDServiceError.missingCredentials }
        start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    if self._auth == .ready { self.lock.unlock(); c.resume(); return }
                    self.readyWaiters.append(c)
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TDServiceError.notReady
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Lifecycle

    /// Creates the TDLib client if credentials exist. Safe to call repeatedly.
    /// Serialises `start()`: launch, scene activation and background backups can call it at the same moment,
    /// and two clients on one database fail with "Can't lock file td.binlog … already in use".
    private let startLock = NSLock()

    func start() {
        startLock.lock()
        defer { startLock.unlock() }
        lock.lock()
        if client != nil { lock.unlock(); return }
        guard TDCredentials.load() != nil else {
            lock.unlock()
            setAuth(.needsCredentials)
            return
        }
        lock.unlock()
        let newClient = manager.createClient { [weak self] data, client in
            self?.handle(data, client: client)
        }
        _ = try? newClient.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
        lock.lock(); client = newClient; loadedChats.removeAll(); lock.unlock()
        setAuth(.starting)
    }

    private func requireClient() throws -> TDLibClient {
        lock.lock(); defer { lock.unlock() }
        guard let client else { throw TDServiceError.notReady }
        return client
    }

    /// Clients whose TDLib instance has fully closed (its database lock is released).
    private var closedClients = Set<ObjectIdentifier>()

    private func isCurrent(_ c: TDLibClient) -> Bool { lock.withLock { client === c } }

    /// Waits until `old` has fully closed, so a new client never opens the database while the old one still holds it
    /// ("Can't lock file td.binlog … already in use").
    private func waitUntilClosed(_ old: TDLibClient?, timeout: TimeInterval = 15) async {
        guard let old else { return }
        let id = ObjectIdentifier(old)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !lock.withLock({ closedClients.contains(id) }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        lock.withLock { _ = closedClients.remove(id) }
    }

    private func handle(_ data: Data, client: TDLibClient) {
        guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
        switch update {
        case .updateAuthorizationState(let u):
            if case .authorizationStateClosed = u.authorizationState {
                lock.withLock { _ = closedClients.insert(ObjectIdentifier(client)) }
            }
            // A client being replaced (sign out, other account) must not drive the sign-in screens or clear the new one.
            guard isCurrent(client) else { return }
            handleAuth(u.authorizationState, client: client)
        case .updateMessageSendSucceeded(let u):
            finishSend(oldId: u.oldMessageId, result: .success(u.message))
        case .updateMessageSendFailed(let u):
            finishSend(oldId: u.oldMessageId, result: .failure(TDServiceError.telegram(code: u.error.code, message: u.error.message)))
        case .updateFile(let u):
            lock.lock()
            let observer = uploadObservers[u.file.id]
            lock.unlock()
            observer?(u.file.remote.uploadedSize, u.file.size)
        default:
            break
        }
    }

    private func handleAuth(_ state: AuthorizationState, client: TDLibClient) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            guard let creds = TDCredentials.load() else { setAuth(.needsCredentials); return }
            Task {
                do {
                    _ = try await client.setTdlibParameters(
                        apiHash: creds.apiHash, apiId: creds.apiId,
                        applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0",
                        databaseDirectory: databaseDirectory.path, databaseEncryptionKey: TDCredentials.databaseKey(),
                        deviceModel: Self.deviceModel, filesDirectory: filesDirectory.path,
                        systemLanguageCode: Locale.preferredLanguages.first ?? "en", systemVersion: "",
                        useChatInfoDatabase: true, useFileDatabase: true,
                        // No message database: interrupted sends are reconciled from history instead of auto-resent.
                        useMessageDatabase: false, useSecretChats: false, useTestDc: false)
                } catch {
                    AppLog.shared.error("setTdlibParameters failed: \(error.asTD.localizedDescription)")
                }
            }
        case .authorizationStateWaitPhoneNumber: setAuth(.waitPhone)
        case .authorizationStateWaitCode(let s):
            setAuth(.waitCode(info: Self.describe(s.codeInfo), length: Self.codeLength(s.codeInfo.type)))
        case .authorizationStateWaitPassword(let s): setAuth(.waitPassword(hint: s.passwordHint))
        case .authorizationStateWaitEmailAddress, .authorizationStateWaitEmailCode: setAuth(.waitEmail)
        case .authorizationStateWaitOtherDeviceConfirmation(let s): setAuth(.waitOtherDevice(link: s.link))
        case .authorizationStateWaitRegistration, .authorizationStateWaitPremiumPurchase: setAuth(.waitRegistration)
        case .authorizationStateReady:
            setAuth(.ready)
            appLog("Telegram session ready")
        case .authorizationStateLoggingOut, .authorizationStateClosing: setAuth(.loggingOut)
        case .authorizationStateClosed:
            lock.withLock { if self.client === client { self.client = nil } }
            setAuth(.closed)
        }
    }

    /// Shown in Telegram → Settings → Devices.
    private static var deviceModel: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    private static func describe(_ info: AuthenticationCodeInfo) -> String {
        switch info.type {
        case .authenticationCodeTypeTelegramMessage: return "Enter the code Telegram sent to your other device or app."
        case .authenticationCodeTypeSms: return "Enter the code sent by SMS to \(info.phoneNumber)."
        case .authenticationCodeTypeSmsWord: return "Enter the word sent by SMS to \(info.phoneNumber)."
        case .authenticationCodeTypeSmsPhrase: return "Enter the phrase sent by SMS to \(info.phoneNumber)."
        case .authenticationCodeTypeCall: return "You'll receive a call with the code."
        case .authenticationCodeTypeMissedCall(let c):
            return "You'll get a missed call from a number starting with \(c.phoneNumberPrefix). Enter its last \(c.length) digits."
        case .authenticationCodeTypeFragment: return "Enter the code shown on fragment.com for your anonymous number."
        default: return "Enter the login code sent to \(info.phoneNumber)."
        }
    }

    /// Digits in the login code (Telegram sends 5 or 6, depending on the account and delivery), 0 for words and phrases.
    private static func codeLength(_ type: AuthenticationCodeType) -> Int {
        switch type {
        case .authenticationCodeTypeTelegramMessage(let c): return c.length
        case .authenticationCodeTypeSms(let c): return c.length
        case .authenticationCodeTypeCall(let c): return c.length
        case .authenticationCodeTypeMissedCall(let c): return c.length
        case .authenticationCodeTypeFragment(let c): return c.length
        case .authenticationCodeTypeFirebaseAndroid(let c): return c.length
        case .authenticationCodeTypeFirebaseIos(let c): return c.length
        case .authenticationCodeTypeSmsWord, .authenticationCodeTypeSmsPhrase, .authenticationCodeTypeFlashCall: return 0
        }
    }

    // MARK: - Login

    func submitPhone(_ phone: String) async throws {
        do { _ = try await requireClient().setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil) } catch { throw error.asTD }
    }

    func submitCode(_ code: String) async throws {
        do { _ = try await requireClient().checkAuthenticationCode(code: code) } catch { throw error.asTD }
    }

    func submitPassword(_ password: String) async throws {
        do { _ = try await requireClient().checkAuthenticationPassword(password: password) } catch { throw error.asTD }
    }

    func logOut() async {
        _ = try? await requireClient().logOut()
    }

    /// Closes TDLib and starts it again with the keys saved now (after the built-in ones were refused).
    func restart() async {
        let old = lock.withLock { client }
        _ = try? await old?.close()
        await waitUntilClosed(old)
        lock.withLock { if client === old { client = nil } }
        start()
    }

    /// Signs out of the current account and starts a fresh login (the api_id/api_hash are kept).
    func switchAccount() async {
        let old = lock.withLock { client }
        await logOut()
        await waitUntilClosed(old)
        lock.withLock { if client === old { client = nil } }
        start()
    }

    /// Days of inactivity after which Telegram deletes the account (and the library channel with it).
    func accountTtlDays() async -> Int? {
        try? await requireClient().getAccountTtl().days
    }

    /// 730 days is Telegram's maximum.
    func setAccountTtl(days: Int) async throws {
        do { _ = try await requireClient().setAccountTtl(ttl: AccountTtl(days: days)) } catch { throw error.asTD }
        appLog("Account self-destruct set to \(days) days")
    }

    func me() async throws -> User {
        do { return try await requireClient().getMe() } catch { throw error.asTD }
    }

    /// "First Last (+phone)" of the signed-in account.
    func displayName() async -> String? {
        guard let u = try? await me() else { return nil }
        let name = [u.firstName, u.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return u.phoneNumber.isEmpty ? name : "\(name) (+\(u.phoneNumber))"
    }

    /// Per-file upload limit: 4000 MiB with Premium, otherwise 2000 MiB.
    func uploadLimit() async -> Int64 {
        (try? await me())?.isPremium == true ? PartLayout.premiumLimit : PartLayout.standardLimit
    }

    // MARK: - Chats

    func api() throws -> TDLibClient { try requireClient() }

    func chat(_ id: Int64) async throws -> Chat {
        do { return try await requireClient().getChat(chatId: id) } catch { throw error.asTD }
    }

    // MARK: - Sending

    private func setUploadObserver(_ id: Int, _ observer: ((Int64, Int64) -> Void)?) {
        lock.withLock { uploadObservers[id] = observer }
    }

    private func awaitSend(_ id: Int64, _ c: CheckedContinuation<Message, Swift.Error>) {
        let done: Result<Message, Swift.Error>? = lock.withLock {
            if let r = finishedSends.removeValue(forKey: id) { return r }
            sendWaiters[id] = c
            return nil
        }
        if let done { c.resume(with: done) }
    }

    private func finishSend(oldId: Int64, result: Result<Message, Swift.Error>) {
        lock.lock()
        if let waiter = sendWaiters.removeValue(forKey: oldId) {
            lock.unlock()
            waiter.resume(with: result)
        } else {
            finishedSends[oldId] = result
            lock.unlock()
        }
    }

    /// Sends a local file as a document and returns only after Telegram confirms it.
    /// `progress` reports (uploaded, total) bytes.
    func sendDocument(chatId: Int64, fileURL: URL, caption: String, thumbnail: (URL, Int, Int)?,
                      progress: ((Int64, Int64) -> Void)? = nil) async throws -> Message {
        await ensureChat(chatId)
        let client = try requireClient()
        let content = InputMessageContent.inputMessageDocument(InputMessageDocument(
            caption: FormattedText(entities: [], text: caption),
            document: InputDocument(
                disableContentTypeDetection: true,
                document: .inputFileLocal(InputFileLocal(path: fileURL.path)),
                thumbnail: thumbnail.map { InputThumbnail(height: $0.2, thumbnail: .inputFileLocal(InputFileLocal(path: $0.0.path)), width: $0.1) })))
        let options = MessageSendOptions(allowPaidBroadcast: false, disableNotification: true, effectId: TdInt64(0),
                                         fromBackground: true, onlyPreview: false, paidMessageStarCount: 0,
                                         protectContent: false, schedulingState: nil, sendingId: 0,
                                         suggestedPostInfo: nil, updateOrderOfInstalledStickerSets: false)
        let pending: Message
        do {
            pending = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: options,
                                                   replyMarkup: nil, replyTo: nil, topicId: nil)
        } catch { throw error.asTD }

        var fileId: Int?
        if case .messageDocument(let doc) = pending.content {
            fileId = doc.document.document.id
            if let progress, let id = fileId { setUploadObserver(id, progress) }
        }
        defer { if let id = fileId { setUploadObserver(id, nil) } }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Message, Swift.Error>) in
                self.awaitSend(pending.id, c)
            }
        } onCancel: {
            Task { _ = try? await client.deleteMessages(chatId: chatId, messageIds: [pending.id], revoke: true) }
            self.finishSend(oldId: pending.id, result: .failure(TDServiceError.cancelled))
        }
    }

    func sendText(chatId: Int64, text: String) async throws -> Message {
        await ensureChat(chatId)
        let client = try requireClient()
        let content = InputMessageContent.inputMessageText(InputMessageText(
            clearDraft: false, linkPreviewOptions: nil, text: FormattedText(entities: [], text: text)))
        do {
            let pending = try await client.sendMessage(chatId: chatId, inputMessageContent: content, options: nil,
                                                       replyMarkup: nil, replyTo: nil, topicId: nil)
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Message, Swift.Error>) in
                self.awaitSend(pending.id, c)
            }
        } catch { throw error.asTD }
    }

    // MARK: - Messages & files

    func message(chatId: Int64, id: Int64) async throws -> Message {
        do { return try await requireClient().getMessage(chatId: chatId, messageId: id) } catch { throw error.asTD }
    }

    /// The document file of a message, or nil if the message is gone or isn't a document.
    func documentFile(chatId: Int64, messageId: Int64) async throws -> (File, Document)? {
        await ensureChat(chatId)
        let msg: Message
        do { msg = try await requireClient().getMessage(chatId: chatId, messageId: messageId) }
        catch {
            let mapped = error.asTD
            AppLog.shared.warn("Reading message \(messageId) failed: \(mapped.localizedDescription)")
            if case TDServiceError.telegram(let code, _)? = mapped as? TDServiceError, code == 404 || code == 400 { return nil }
            throw mapped
        }
        guard case .messageDocument(let d) = msg.content else { return nil }
        return (d.document.document, d.document)
    }

    /// Reads `count` bytes at `offset`, downloading just that range with high priority.
    /// TDLib keeps one download offset per file, so reads of the same file are serialised;
    /// ranges already on disk are served without touching the network.
    func read(fileId: Int, offset: Int64, count: Int64, priority: Int = 32) async throws -> Data {
        let client = try requireClient()
        let gate = fileGate(fileId)
        await gate.acquire()
        defer { Task { await gate.release() } }
        var lastError: Swift.Error = TDServiceError.notReady
        for attempt in 0..<3 {
            do {
                let have = (try? await client.getFileDownloadedPrefixSize(fileId: fileId, offset: offset))?.size ?? 0
                if have < count {
                    _ = try await client.downloadFile(fileId: fileId, limit: count, offset: offset, priority: priority, synchronous: true)
                }
                let data = try await readPart(client, fileId: fileId, offset: offset, count: count)
                if Int64(data.count) >= count || attempt == 2 { return data }
            } catch {
                lastError = error.asTD
                if case .floodWait(let s)? = (lastError as? TDServiceError)?.kind {
                    try await Task.sleep(nanoseconds: UInt64(max(1, s)) * 1_000_000_000)
                }
            }
            try Task.checkCancellation()
        }
        if let f = try? await client.getFile(fileId: fileId) {
            let have = (try? await client.getFileDownloadedPrefixSize(fileId: fileId, offset: offset))?.size ?? -1
            AppLog.shared.warn("Read failed: file \(fileId) size \(f.size) offset \(offset) count \(count) prefixAtOffset \(have) "
                + "local downloaded \(f.local.downloadedSize) prefix \(f.local.downloadedPrefixSize) complete \(f.local.isDownloadingCompleted) "
                + "active \(f.local.isDownloadingActive) canDownload \(f.local.canBeDownloaded) path '\(f.local.path)'")
        }
        throw lastError
    }

    /// Where the continuous streaming download of each file started (TDLib keeps one download per file).
    private var streamWindows: [Int: Int64] = [:]

    /// Streaming read for the video player: keeps one continuous TDLib download running ahead of the
    /// playhead, like Telegram's own player, instead of one request per slice (which can't keep up with 4K).
    /// Small reads elsewhere in the file (the player's probes and the `moov` index at the end) are fetched
    /// on their own under the file gate, so they don't fight the main download over TDLib's single slot.
    func streamRead(fileId: Int, offset: Int64, count: Int64) async throws -> Data {
        let client = try requireClient()
        let started = Foundation.Date()
        var myWindow: Int64?
        var lastIssue: Foundation.Date?
        var lastReport = started
        while true {
            try Task.checkCancellation()
            let have = (try? await client.getFileDownloadedPrefixSize(fileId: fileId, offset: offset))?.size ?? 0
            if have >= count { break }
            let file = try await client.getFile(fileId: fileId)
            if Foundation.Date().timeIntervalSince(lastReport) > 5 {
                lastReport = Foundation.Date()
                let waited = Int(lastReport.timeIntervalSince(started))
                let window = lock.withLock { streamWindows[fileId] }
                AppLog.shared.warn("Stream stuck \(waited) s: file \(fileId) want \(count) at \(offset), have \(have); window \(window.map(String.init) ?? "none"); "
                    + "active \(file.local.isDownloadingActive) downloaded \(file.local.downloadedSize)/\(file.size) canDownload \(file.local.canBeDownloaded) "
                    + "remote '\(file.remote.id.prefix(12))…' uploaded \(file.remote.isUploadingCompleted) path '\(file.local.path.suffix(60))'")
                if waited >= 30 { throw TDServiceError.sendFailed("Telegram didn't deliver this video's data for 30 s") }
            }
            if file.local.isDownloadingCompleted || (file.size > 0 && offset + have >= Int64(file.size)) { break }
            let window = lock.withLock { streamWindows[fileId] }
            let reach: Int64 = await {
                guard let window, window <= offset, file.local.isDownloadingActive else { return -1 }
                return (try? await client.getFileDownloadedPrefixSize(fileId: fileId, offset: window))?.size ?? 0
            }()
            let covered = window.map { reach >= 0 && offset <= $0 + reach + (2 << 20) } ?? false
            if !covered && count <= 512 << 10 {
                // Small read outside the window: fetch just this range; the gate holds the window back meanwhile.
                let gate = fileGate(fileId)
                await gate.acquire()
                defer { Task { await gate.release() } }
                lock.withLock { streamWindows[fileId] = nil }
                _ = try? await client.downloadFile(fileId: fileId, limit: count, offset: offset, priority: 32, synchronous: true)
                break
            }
            // Move the window when it doesn't cover us: immediately if a small read stopped it,
            // otherwise only after a fresh download has had a moment to report as active.
            let movedByOthers = myWindow != nil && window == nil
            if !covered && (lastIssue == nil || movedByOthers || Foundation.Date().timeIntervalSince(lastIssue ?? .distantPast) > 2) {
                let gate = fileGate(fileId)
                await gate.acquire()
                do {
                    _ = try await client.downloadFile(fileId: fileId, limit: 0, offset: offset, priority: 32, synchronous: false)
                    lock.withLock { streamWindows[fileId] = offset }
                } catch {
                    await gate.release()
                    throw error.asTD
                }
                await gate.release()
                myWindow = offset
                lastIssue = Foundation.Date()
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let waited = Foundation.Date().timeIntervalSince(started)
        if waited > 1 { AppLog.shared.warn(String(format: "Playback waited %.1f s for %lld bytes at %lld (file %d)", waited, count, offset, fileId)) }
        return try await readPart(client, fileId: fileId, offset: offset, count: count)
    }

    /// `readFilePart`, recovering from TDLib's stale local copies. Files this device uploaded keep the
    /// upload's temporary copy as their "downloaded" location; TDLib refuses to read outside its cache
    /// ("File is not inside the cache") and keeps that location after the copy is deleted or the app
    /// container moves on reinstall ("Failed to read the file"), so the video never streams.
    private func readPart(_ client: TDLibClient, fileId: Int, offset: Int64, count: Int64) async throws -> Data {
        do {
            return try await client.readFilePart(count: count, fileId: fileId, offset: offset).data
        } catch {
            let first = error.asTD
            guard let f = try? await client.getFile(fileId: fileId) else { throw first }
            let path = f.local.path
            if f.local.isDownloadingCompleted, !path.isEmpty, FileManager.default.isReadableFile(atPath: path),
               let handle = FileHandle(forReadingAtPath: path) {
                // The exact bytes that were uploaded are still here: read them directly.
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: Int(count)) ?? Data()
            }
            // The copy is gone: a download makes TDLib check the location, drop it and fetch from Telegram.
            AppLog.shared.warn("Re-downloading file \(fileId): local copy unusable (\(first.localizedDescription))")
            lock.withLock { streamWindows[fileId] = nil }
            do {
                _ = try await client.downloadFile(fileId: fileId, limit: count, offset: offset, priority: 32, synchronous: true)
                return try await client.readFilePart(count: count, fileId: fileId, offset: offset).data
            } catch {
                throw error.asTD
            }
        }
    }

    private var fileGates: [Int: AsyncGate] = [:]
    private var loadedChats = Set<Int64>()

    /// TDLib only knows chats it has loaded in this session; after a restart the library channel must be
    /// loaded before its messages can be read ("Chat not found" otherwise).
    func ensureChat(_ chatId: Int64) async {
        if lock.withLock({ loadedChats.contains(chatId) }) { return }
        guard let client = try? requireClient() else { return }
        var ok = (try? await client.getChat(chatId: chatId)) != nil
        if !ok {
            // Channel chat ids are -100<supergroup id>.
            let supergroupId = -(chatId + 1_000_000_000_000)
            if supergroupId > 0 { ok = (try? await client.createSupergroupChat(force: true, supergroupId: supergroupId)) != nil }
        }
        if !ok {
            _ = try? await client.loadChats(chatList: .chatListMain, limit: 500)
            ok = (try? await client.getChat(chatId: chatId)) != nil
        }
        if ok { lock.withLock { _ = loadedChats.insert(chatId) } }
        else { AppLog.shared.warn("Couldn't load the library channel") }
    }

    private func fileGate(_ id: Int) -> AsyncGate {
        lock.withLock {
            if let g = fileGates[id] { return g }
            let g = AsyncGate()
            fileGates[id] = g
            return g
        }
    }

    /// Downloads the whole file and returns its local path.
    func download(fileId: Int, priority: Int = 16) async throws -> URL {
        // Same per-file gate as ranged reads: TDLib runs one download per file and cancels the other
        // ("Canceled by another downloadFile request"), e.g. sharing a video while it streams.
        let gate = fileGate(fileId)
        await gate.acquire()
        defer { Task { await gate.release() } }
        do {
            let client = try requireClient()
            let file = try await client.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: priority, synchronous: true)
            guard file.local.isDownloadingCompleted else { throw TDServiceError.sendFailed("download incomplete") }
            return URL(fileURLWithPath: file.local.path)
        } catch { throw error.asTD }
    }

    /// Downloads a file by its persistent remote id (no message lookup, so no extra round trip to Telegram).
    func download(remoteId: String, priority: Int = 16) async throws -> URL {
        let file: File
        do { file = try await requireClient().getRemoteFile(fileType: nil, remoteFileId: remoteId) } catch { throw error.asTD }
        if file.local.isDownloadingCompleted, FileManager.default.fileExists(atPath: file.local.path) {
            return URL(fileURLWithPath: file.local.path)
        }
        return try await download(fileId: file.id, priority: priority)
    }

    /// Removes TDLib's downloaded copy of a file from its cache (the file stays in Telegram).
    func deleteLocalCopy(fileId: Int) async {
        _ = try? await requireClient().deleteFile(fileId: fileId)
    }

    func cancelDownload(fileId: Int) {
        guard let client = try? requireClient() else { return }
        Task { _ = try? await client.cancelDownloadFile(fileId: fileId, onlyIfPending: false) }
    }

    func history(chatId: Int64, fromMessageId: Int64, limit: Int = 100) async throws -> [Message] {
        await ensureChat(chatId)
        do {
            return try await requireClient().getChatHistory(chatId: chatId, fromMessageId: fromMessageId, limit: limit,
                                                            offset: 0, onlyLocal: false).messages ?? []
        } catch { throw error.asTD }
    }

    func deleteMessages(chatId: Int64, ids: [Int64]) async throws {
        await ensureChat(chatId)
        guard !ids.isEmpty else { return }
        do { _ = try await requireClient().deleteMessages(chatId: chatId, messageIds: ids, revoke: true) } catch { throw error.asTD }
    }

    /// Keeps TDLib's own file cache within `maxBytes`.
    func optimizeStorage(maxBytes: Int64) async {
        _ = try? await requireClient().optimizeStorage(chatIds: nil, chatLimit: 0, count: -1, excludeChatIds: nil,
                                                       fileTypes: nil, immunityDelay: 60, returnDeletedFileStatistics: false,
                                                       size: maxBytes, ttl: 7 * 24 * 3600)
    }

    /// Deletes every downloaded file (Settings → Storage → Clear): TDLib's cache with no age/size/immunity
    /// exceptions, then any leftovers TDLib no longer tracks (stale partial downloads). Anything needed again
    /// is re-downloaded from Telegram on demand (see `readPart` recovery).
    func clearAllFiles() async {
        if let client = try? requireClient() {
            _ = try? await client.optimizeStorage(chatIds: nil, chatLimit: 0, count: 0, excludeChatIds: nil,
                                                 fileTypes: nil, immunityDelay: 0, returnDeletedFileStatistics: false,
                                                 size: 0, ttl: 0)
        }
        let fm = FileManager.default
        for sub in (try? fm.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: file)
            }
        }
        lock.withLock { streamWindows.removeAll() }
    }

    func storageUsage() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: filesDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Wipes the TDLib session and files (used by "Sign out & reset").
    func destroyLocalData() async {
        let old = lock.withLock { client }
        _ = try? await old?.destroy()
        await waitUntilClosed(old)
        lock.withLock { if client === old { client = nil } }
        try? FileManager.default.removeItem(at: databaseDirectory)
        try? FileManager.default.removeItem(at: filesDirectory)
        try? FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        setAuth(TDCredentials.load() == nil ? .needsCredentials : .closed)
    }
}

/// The app's api_id / api_hash (my.telegram.org) and the TDLib database key. The keys are built into the app
/// (Config/Secrets.xcconfig → Info.plist), like Telegram's own apps, so sign-in starts at the phone number;
/// keys entered by hand (builds without them) are kept in the Keychain and take precedence.
struct TDCredentials {
    let apiId: Int
    let apiHash: String

    static func load() -> TDCredentials? {
        if let idString = KeychainStore.string(for: .tdApiId), let id = Int(idString),
           let hash = KeychainStore.string(for: .tdApiHash), !hash.isEmpty {
            return TDCredentials(apiId: id, apiHash: hash)
        }
        return bundled
    }

    /// Whether sign-in is running on the built-in keys (nothing entered by hand).
    static var usingBundled: Bool { KeychainStore.string(for: .tdApiId) == nil && bundled != nil }

    /// Keys built into this copy of the app, if any.
    static var bundled: TDCredentials? {
        let info = Bundle.main.infoDictionary
        guard let idString = (info?["TDAPIId"] as? String)?.trimmingCharacters(in: .whitespaces), let id = Int(idString), id > 0,
              let hash = (info?["TDAPIHash"] as? String)?.trimmingCharacters(in: .whitespaces), hash.count == 32 else { return nil }
        return TDCredentials(apiId: id, apiHash: hash)
    }

    static func save(apiId: Int, apiHash: String) {
        KeychainStore.set(String(apiId), for: .tdApiId)
        KeychainStore.set(apiHash, for: .tdApiHash)
    }

    static func databaseKey() -> Data {
        if let key = KeychainStore.data(for: .tdDatabaseKey), key.count == 32 { return key }
        let key = KeyDerivation.randomSalt(count: 32)
        KeychainStore.set(key, for: .tdDatabaseKey)
        return key
    }
}

/// A FIFO async mutex.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
