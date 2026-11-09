import Foundation
import Testing
import LelvoCore

@Suite struct FeedbackTests {
    let env = Feedback.Environment(app: "iPhone", version: "0.1.0 (12)", device: "iPhone17,1", os: "iOS 26.1")

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func bugDraftGreetsTheDeveloperAndEndsWithTheAppDetails() {
        let text = Feedback.draft(.bug, appName: "Lelvo", developer: "Shahil", env: env)
        #expect(text.hasPrefix("Hi Shahil,"))
        #expect(text.contains("What happened instead:"))
        #expect(text.hasSuffix("Lelvo 0.1.0 (12), iPhone17,1, iOS 26.1"))
    }

    @Test func ideaDraftAsksForTheIdeaAndWhy() {
        let text = Feedback.draft(.idea, appName: "Lelvo", developer: "Shahil", env: env)
        #expect(text.contains("What I'd like:"))
        #expect(text.contains("Why it would help:"))
        #expect(!text.contains("What happened instead:"))
    }

    /// Newlines, ampersands and plus signs must survive, or the draft arrives cut short or with spaces turned into "+".
    @Test func mailLinkCarriesSubjectAndDraftUnchanged() throws {
        let text = "Line one & two\n\n1 + 1 = 2? #yes 📷"
        let subject = Feedback.subject(.bug, appName: "Lelvo")
        let url = try #require(Feedback.mailURL(to: "dev@example.com", subject: subject, body: text))
        #expect(url.scheme == "mailto")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.path == "dev@example.com")
        #expect(query(url)["subject"] == "Lelvo: something isn't working")
        #expect(query(url)["body"] == text)
        #expect(!url.absoluteString.contains("+"))
    }

    @Test func ideaSubjectSaysItIsAnIdea() {
        #expect(Feedback.subject(.idea, appName: "Lelvo") == "Lelvo: an idea")
    }

    @Test func bugIssueOpensTheBugTemplateWithDetailsFilledIn() throws {
        let repo = URL(string: "https://github.com/shahil-kv/Lelvo")!
        let url = try #require(Feedback.gitHubIssueURL(repository: repo, kind: .bug, env: env))
        #expect(url.path == "/shahil-kv/Lelvo/issues/new")
        let q = query(url)
        #expect(q["template"] == "bug_report.yml")
        #expect(q["app"] == "iPhone")
        #expect(q["version"] == "0.1.0 (12)")
        #expect(q["os"] == "iPhone17,1, iOS 26.1")
    }

    @Test func ideaIssueOpensTheFeatureTemplate() throws {
        let repo = URL(string: "https://github.com/shahil-kv/Lelvo")!
        let url = try #require(Feedback.gitHubIssueURL(repository: repo, kind: .idea, env: env))
        let q = query(url)
        #expect(q["template"] == "feature_request.yml")
        #expect(q["app"] == "iPhone")
        #expect(q["version"] == nil)
    }
}
