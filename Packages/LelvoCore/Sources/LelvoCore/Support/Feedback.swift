import Foundation

/// Links and message drafts behind Settings → Report a problem and Suggest a feature. The app never sends anything
/// itself: it opens Telegram or GitHub with the text ready, and the user presses send.
public enum Feedback {
    public enum Kind: Sendable {
        case bug, idea
    }

    /// What the app runs on, put into every draft so a bug can be reproduced without asking back. Nothing personal.
    public struct Environment: Sendable, Equatable {
        public var app: String      // matches the "App" dropdown in the issue templates: iPhone, iPad or Mac
        public var version: String
        public var device: String
        public var os: String

        public init(app: String, version: String, device: String, os: String) {
            self.app = app
            self.version = version
            self.device = device
            self.os = os
        }
    }

    public static func draft(_ kind: Kind, appName: String, developer: String, env: Environment) -> String {
        let body: String
        switch kind {
        case .bug:
            body = "Hi \(developer), something isn't working in \(appName).\n\nWhat I was doing:\n\n\nWhat happened instead:\n\n"
        case .idea:
            body = "Hi \(developer), I have an idea for \(appName).\n\nWhat I'd like:\n\n\nWhy it would help:\n\n"
        }
        return body + "\n— \(appName) \(env.version), \(env.device), \(env.os)"
    }

    /// A t.me link that opens a chat with `username` and puts `text` in the message box. Telegram doesn't decode "+"
    /// as a space, so spaces are sent as %20.
    public static func telegramURL(username: String, text: String) -> URL? {
        URL(string: "https://t.me/\(username)?text=\(encode(text))")
    }

    /// The repository's issue form for `kind`, with the fields the form has filled in from `env`. GitHub fills a form
    /// field from the query parameter named after its `id`; see .github/ISSUE_TEMPLATE.
    public static func gitHubIssueURL(repository: URL, kind: Kind, env: Environment) -> URL? {
        var fields: [(String, String)]
        switch kind {
        case .bug:
            fields = [("template", "bug_report.yml"), ("app", env.app), ("version", env.version),
                      ("os", "\(env.device), \(env.os)")]
        case .idea:
            fields = [("template", "feature_request.yml"), ("app", env.app)]
        }
        let query = fields.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: repository.absoluteString + "/issues/new?" + query)
    }

    private static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }
}
