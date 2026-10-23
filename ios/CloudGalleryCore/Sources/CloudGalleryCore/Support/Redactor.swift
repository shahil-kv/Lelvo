import Foundation

/// Strips secrets from text before it is logged or shared.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = [
        // Bot token: <digits>:<35 url-safe chars>, also inside api.telegram.org/bot<token>/ URLs.
        (try! NSRegularExpression(pattern: #"\d{5,}:[A-Za-z0-9_-]{30,}"#), "<bot-token>"),
        // Channel / supergroup ids.
        (try! NSRegularExpression(pattern: #"-100\d{6,}"#), "<chat-id>"),
        // file_id values (long base64url strings).
        (try! NSRegularExpression(pattern: #"\b[A-Za-z0-9_-]{60,}\b"#), "<file-id>")
    ]

    public static func redact(_ text: String, extraSecrets: [String] = []) -> String {
        var result = text
        for secret in extraSecrets where secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
