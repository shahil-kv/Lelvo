import Foundation

public enum TelegramError: Error, Equatable, LocalizedError {
    /// HTTP 429 — Telegram asks us to wait `retryAfter` seconds.
    case rateLimited(retryAfter: Int)
    /// Telegram returned ok=false.
    case api(code: Int, description: String)
    /// Non-JSON / unexpected HTTP status.
    case http(status: Int)
    case decoding(String)
    case network(String)
    case fileTooLargeToDownload
    case missingResult

    public var errorDescription: String? {
        switch self {
        case .rateLimited(let s): return "Telegram rate limit reached. Retrying in \(s) s."
        case .api(let code, let d):
            switch code {
            case 401: return "The bot token is invalid (Telegram said: \(d))."
            case 403: return "The bot has no access to this chat. Make sure it is an admin. (\(d))"
            case 400 where d.localizedCaseInsensitiveContains("chat not found"):
                return "Chat not found. Check the chat ID and that the bot was added to it."
            default: return "Telegram error \(code): \(d)"
            }
        case .http(let s): return "Unexpected HTTP status \(s) from Telegram."
        case .decoding(let d): return "Could not read Telegram's response: \(d)"
        case .network(let d): return "Network error: \(d)"
        case .fileTooLargeToDownload: return "This file is larger than 20 MB, which the Bot API cannot download. It needs version 2."
        case .missingResult: return "Telegram returned no result."
        }
    }

    /// Whether retrying the same request later could succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .network: return true
        case .http(let s): return s >= 500
        case .api(let code, _): return code >= 500
        default: return false
        }
    }
}

public enum TelegramResponseParser {
    private static let decoder = JSONDecoder()

    /// Decodes a Bot API response body, mapping failures to `TelegramError`.
    public static func parse<T: Decodable>(_ type: T.Type, data: Data, statusCode: Int) throws -> T {
        let envelope: TGResponse<T>
        do {
            envelope = try decoder.decode(TGResponse<T>.self, from: data)
        } catch {
            if statusCode == 429 { throw TelegramError.rateLimited(retryAfter: 5) }
            if statusCode >= 400 || statusCode < 200 { throw TelegramError.http(status: statusCode) }
            throw TelegramError.decoding(String(describing: error))
        }
        if envelope.ok, let result = envelope.result { return result }
        if envelope.ok { throw TelegramError.missingResult }
        let code = envelope.errorCode ?? statusCode
        if code == 429 || envelope.parameters?.retryAfter != nil {
            throw TelegramError.rateLimited(retryAfter: max(1, envelope.parameters?.retryAfter ?? 5))
        }
        throw TelegramError.api(code: code, description: envelope.description ?? "Unknown error")
    }
}
