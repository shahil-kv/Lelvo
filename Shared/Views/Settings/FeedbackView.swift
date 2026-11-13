import SwiftUI
import LelvoCore

/// Report a problem / Suggest a feature: what helps, then a choice between the Lelvo group on Telegram and an email to
/// the developer. Both come with the app version and device filled in; the user sends it themselves.
struct FeedbackView: View {
    let kind: Feedback.Kind

    private var env: Feedback.Environment {
        Feedback.Environment(app: Device.kind, version: Bundle.main.displayVersion, device: Device.model, os: Device.osVersion)
    }

    private var mailURL: URL? {
        Feedback.mailURL(to: AppLinks.developerEmail, subject: Feedback.subject(kind, appName: "Lelvo"),
                         body: Feedback.draft(kind, appName: "Lelvo", developer: AppLinks.developerName, env: env))
    }

    private func email() {
        guard let mailURL else { copyAddress(); return }
        PlatformActions.open(mailURL) { opened in
            if !opened { copyAddress(noMailApp: true) }
        }
    }

    /// Telegram doesn't let an app type into a group: the report goes on the clipboard and the topic opens to paste in.
    private func postInGroup() {
        PlatformActions.copy(Feedback.groupPost(kind, appName: "Lelvo", env: env))
        ToastCenter.shared.show(.info, kind == .bug ? "Report copied. Paste it in the group and send." : "Idea copied. Paste it in the group and send.")
        PlatformActions.open(kind == .bug ? AppLinks.communityBugs : AppLinks.communityIdeas)
    }

    private func copyAddress(noMailApp: Bool = false) {
        PlatformActions.copy(AppLinks.developerEmail)
        ToastCenter.shared.show(.info, noMailApp ? "No mail app is set up. The address is copied." : "Address copied")
    }

    var body: some View {
        Form {
            Section {
                Text("You're writing to \(AppLinks.developerName), the one person who builds Lelvo. I read every message myself, so a reply can take a little while, but I'll get back to you as soon as I can.")
            }

            Section {
                switch kind {
                case .bug:
                    Label("What you were doing, and what you expected", systemImage: "hand.tap")
                    Label("What happened instead", systemImage: "exclamationmark.triangle")
                    Label("A screen recording or screenshots", systemImage: "record.circle")
                    NavigationLink { LogsView() } label: { Label("Your logs: open Logs and share the file", systemImage: "doc.text.magnifyingglass") }
                case .idea:
                    Label("What you'd like Lelvo to do", systemImage: "lightbulb")
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
                Button(action: postInGroup) {
                    Label {
                        Text("Post in the Lelvo group")
                        Text("Opens \(kind == .bug ? "Bugs" : "Feature ideas") in Telegram with your \(kind == .bug ? "report" : "idea") copied. Paste it there.")
                    } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                }
                Button(action: email) {
                    Label {
                        Text("Email \(AppLinks.developerName)")
                        Text(AppLinks.developerEmail)
                    } icon: { Image(systemName: "envelope") }
                }
            } header: {
                Text("Send it")
            } footer: {
                Text("Both come with your app version and \(Device.name) model filled in, nothing else. Everyone in the group can read what you post there. By email only \(AppLinks.developerName) reads it, and sees your email address.")
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
