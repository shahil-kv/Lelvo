import SwiftUI
import MemvoCore

/// Report a problem / Suggest a feature: what helps, then a choice between a Telegram message to the developer and a
/// GitHub issue. Both open with the app version and device filled in; the user sends it themselves.
struct FeedbackView: View {
    let kind: Feedback.Kind

    private var env: Feedback.Environment {
        Feedback.Environment(app: Device.kind, version: Bundle.main.displayVersion, device: Device.model, os: Device.osVersion)
    }

    private var telegramURL: URL? {
        Feedback.telegramURL(username: AppLinks.developerTelegram,
                             text: Feedback.draft(kind, appName: "Memvo", developer: AppLinks.developerName, env: env))
    }

    var body: some View {
        Form {
            Section {
                Text("You're writing to \(AppLinks.developerName), the one person who builds Memvo. I read every message myself, so a reply can take a little while, but I'll get back to you as soon as I can.")
            }

            Section {
                switch kind {
                case .bug:
                    Label("What you were doing, and what you expected", systemImage: "hand.tap")
                    Label("What happened instead", systemImage: "exclamationmark.triangle")
                    Label("A screen recording or screenshots", systemImage: "record.circle")
                    NavigationLink { LogsView() } label: { Label("Your logs: open Logs and share the file", systemImage: "doc.text.magnifyingglass") }
                case .idea:
                    Label("What you'd like Memvo to do", systemImage: "lightbulb")
                    Label("Why it would help you", systemImage: "heart")
                    Label("A screenshot or sketch, if it helps", systemImage: "photo")
                }
            } header: {
                Text(kind == .bug ? "What helps me fix it" : "What helps")
            } footer: {
                if kind == .bug {
                    Text("Phone numbers, API keys, channel IDs and file IDs are removed from logs before they're shared.")
                }
            }

            Section {
                if let telegramURL {
                    Button { PlatformActions.open(telegramURL) } label: {
                        Label("Message \(AppLinks.developerName) on Telegram", systemImage: "paperplane")
                    }
                }
                if let issue = Feedback.gitHubIssueURL(repository: AppLinks.repository, kind: kind, env: env) {
                    Link(destination: issue) { Label("Create an issue on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                }
            } footer: {
                Text("Telegram opens with a message ready for you to finish and send, with your app version and \(Device.name) model filled in. \(AppLinks.developerName) will see your Telegram name. GitHub issues are public and need a GitHub account.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind == .bug ? "Report a problem" : "Suggest a feature")
    }
}

extension Bundle {
    /// "0.1.0 (12)": the marketing version and the build number, as About shows them.
    var displayVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
