import Foundation

/// Foreground Bot API client. Long-running media uploads go through the app's background
/// `URLSession`; this client handles control calls, small uploads and downloads.
public final class TelegramClient: @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "https://api.telegram.org") ?? URL(fileURLWithPath: "/")
    /// Bot API hard limits.
    public static let maxUploadBytes: Int64 = 50 * 1024 * 1024
    public static let maxDownloadBytes: Int64 = 20 * 1024 * 1024

    public let token: String
    public let baseURL: URL
    public let limiter: RateLimiter
    private let session: URLSession
    private let backoff: BackoffPolicy

    public init(token: String, baseURL: URL = TelegramClient.defaultBaseURL, session: URLSession = .shared,
                limiter: RateLimiter = RateLimiter(), backoff: BackoffPolicy = BackoffPolicy()) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
        self.limiter = limiter
        self.backoff = backoff
    }

    public func methodURL(_ method: String) -> URL {
        baseURL.appendingPathComponent("bot\(token)").appendingPathComponent(method)
    }

    public func fileURL(path: String) -> URL {
        baseURL.appendingPathComponent("file").appendingPathComponent("bot\(token)").appendingPathComponent(path)
    }

    // MARK: - Generic call

    func call<T: Decodable>(_ method: String, params: [String: Any] = [:], as type: T.Type, paced: Bool = false) async throws -> T {
        var request = URLRequest(url: methodURL(method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        request.timeoutInterval = 60
        return try await perform(request, as: type, paced: paced)
    }

    func perform<T: Decodable>(_ request: URLRequest, as type: T.Type, paced: Bool) async throws -> T {
        var attempt = 0
        while true {
            if paced { await limiter.wait() }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return try TelegramResponseParser.parse(type, data: data, statusCode: status)
            } catch {
                let mapped: Error = (error as? URLError).map { TelegramError.network($0.localizedDescription) } ?? error
                if case TelegramError.rateLimited(let s) = mapped { await limiter.penalize(retryAfter: TimeInterval(s)) }
                switch backoff.decide(error: mapped, attempt: attempt) {
                case .retry(let delay):
                    attempt += 1
                    // Paced calls already wait for the penalised slot inside `limiter.wait()`.
                    let limiterWaits: Bool
                    if case TelegramError.rateLimited = mapped { limiterWaits = paced } else { limiterWaits = false }
                    if !limiterWaits { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                case .giveUp:
                    throw mapped
                }
            }
        }
    }

    // MARK: - Methods

    public func getMe() async throws -> TGUser {
        try await call("getMe", as: TGUser.self)
    }

    public func getUpdates(offset: Int64? = nil) async throws -> [TGUpdate] {
        var p: [String: Any] = ["timeout": 0,
                                "allowed_updates": ["message", "channel_post", "my_chat_member"]]
        if let offset { p["offset"] = offset }
        return try await call("getUpdates", params: p, as: [TGUpdate].self)
    }

    public func getChat(_ chatId: String) async throws -> TGChat {
        try await call("getChat", params: ["chat_id": chatId], as: TGChat.self)
    }

    public func getChatMember(chatId: String, userId: Int64) async throws -> TGChatMember {
        try await call("getChatMember", params: ["chat_id": chatId, "user_id": userId], as: TGChatMember.self)
    }

    /// Verifies the bot is an admin of `chatId` with post/delete/pin rights.
    public func checkPermissions(chatId: String) async throws -> BotPermissionReport {
        let me = try await getMe()
        let chat = try await getChat(chatId)
        let member = try await getChatMember(chatId: chatId, userId: me.id)
        return BotPermissionReport(member: member, chatType: chat.type)
    }

    public func getFile(_ fileId: String) async throws -> TGFile {
        try await call("getFile", params: ["file_id": fileId], as: TGFile.self)
    }

    public func deleteMessage(chatId: String, messageId: Int64) async throws {
        _ = try await call("deleteMessage", params: ["chat_id": chatId, "message_id": messageId], as: Bool.self, paced: true)
    }

    public func pinChatMessage(chatId: String, messageId: Int64) async throws {
        _ = try await call("pinChatMessage", params: ["chat_id": chatId, "message_id": messageId,
                                                      "disable_notification": true], as: Bool.self, paced: true)
    }

    public func unpinChatMessage(chatId: String, messageId: Int64) async throws {
        _ = try await call("unpinChatMessage", params: ["chat_id": chatId, "message_id": messageId], as: Bool.self, paced: true)
    }

    /// Probes whether a message still exists without changing it: re-sending the identical caption
    /// yields "message is not modified" when it exists and "message to edit not found" when it doesn't.
    public func messageExists(chatId: String, messageId: Int64, caption: String) async throws -> Bool {
        do {
            _ = try await call("editMessageCaption", params: ["chat_id": chatId, "message_id": messageId,
                                                              "caption": caption], as: AnyDecodable.self, paced: true)
            return true
        } catch TelegramError.api(_, let description) {
            let d = description.lowercased()
            if d.contains("not modified") { return true }
            if d.contains("not found") || d.contains("message_id_invalid") {
                return false
            }
            throw TelegramError.api(code: 400, description: description)
        }
    }

    /// Small in-memory upload (index chunks, manifest). Media uses the background session instead.
    public func sendDocument(chatId: String, data: Data, fileName: String, mimeType: String = "application/octet-stream",
                             caption: String? = nil) async throws -> TGMessage {
        let body = MultipartBody()
        var fields: [(String, String)] = [("chat_id", chatId), ("disable_notification", "true"),
                                          ("disable_content_type_detection", "true")]
        if let caption { fields.append(("caption", caption)) }
        var request = URLRequest(url: methodURL("sendDocument"))
        request.httpMethod = "POST"
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(fields: fields, fieldName: "document", fileName: fileName, mimeType: mimeType, fileData: data)
        request.timeoutInterval = 300
        return try await perform(request, as: TGMessage.self, paced: true)
    }

    /// Downloads a file (≤ 20 MB) to `destination`.
    public func download(fileId: String, to destination: URL) async throws -> Int64 {
        let file = try await getFile(fileId)
        if let size = file.fileSize, size > Self.maxDownloadBytes { throw TelegramError.fileTooLargeToDownload }
        guard let path = file.filePath else { throw TelegramError.fileTooLargeToDownload }
        let (tmp, response) = try await session.download(from: fileURL(path: path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: tmp)
            throw TelegramError.http(status: status)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
        let attrs = try fm.attributesOfItem(atPath: destination.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func downloadData(fileId: String) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try await download(fileId: fileId, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try Data(contentsOf: tmp)
    }
}

/// Accepts any JSON value (used where we only care about success).
public struct AnyDecodable: Decodable {
    public init(from decoder: Decoder) throws {}
}
