import Foundation

/// Links and message drafts behind Settings → Report a problem and Suggest a feature. The app never sends anything
/// itself: it opens Mail or GitHub with the text ready, and the user presses send.
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

    /// The same report for the Lelvo group on Telegram, matching the template pinned in its Bugs and Feature ideas
    /// topics. Telegram doesn't let an app type into a group, so the app copies this and opens the topic to paste in.
    public static func groupPost(_ kind: Kind, appName: String, env: Environment) -> String {
        switch kind {
        case .bug:
            return "🐞 Bug\n\nWhat I did:\n\nWhat I expected:\n\nWhat happened instead:\n\nHow often: every time / sometimes / once\n"
                + "Phone: \(env.device), \(env.os)\n\(appName) version: \(env.version) (\(env.app))"
        case .idea:
            return "💡 Feature idea\n\nWhat I'd like \(appName) to do:\n\nWhy it would help me:\n\nHow I do it today:\n\n"
                + "\(appName) \(env.version) (\(env.app)), \(env.device)"
        }
    }

    /// The subject line of an email draft.
    public static func subject(_ kind: Kind, appName: String) -> String {
        kind == .bug ? "\(appName): something isn't working" : "\(appName): an idea"
    }

    /// A mailto link with the subject and body filled in. Mail apps don't decode "+" as a space, so spaces are sent
    /// as %20, and "&" inside the text is encoded so it doesn't end the body early.
    public static func mailURL(to address: String, subject: String, body: String) -> URL? {
        URL(string: "mailto:\(address)?subject=\(encode(subject))&body=\(encode(body))")
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
