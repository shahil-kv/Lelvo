import SwiftUI
import LelvoCore
#if os(iOS)
import MessageUI
#endif

/// Report a problem / Suggest a feature: what helps, then a choice between the Lelvo group on Telegram and an email to
/// the developer. Both come with the app version and device filled in; the user sends it themselves. Bug reports also
/// offer the redacted log file so it can be attached in Mail or Telegram.
struct FeedbackView: View {
    let kind: Feedback.Kind

    @State private var share: ShareItems?
    #if os(iOS)
    @State private var mailDraft: MailDraft?
    #endif

    private var env: Feedback.Environment {
        Feedback.Environment(app: Device.kind, version: Bundle.main.displayVersion, device: Device.model, os: Device.osVersion)
    }

    private var draftBody: String {
        Feedback.draft(kind, appName: "Lelvo", developer: AppLinks.developerName, env: env)
    }

    private var mailURL: URL? {
        Feedback.mailURL(to: AppLinks.developerEmail, subject: Feedback.subject(kind, appName: "Lelvo"), body: draftBody)
    }

    private func email() {
        #if os(iOS)
        if kind == .bug, MFMailComposeViewController.canSendMail(), let log = AppLog.shared.exportFile() {
            mailDraft = MailDraft(
                to: AppLinks.developerEmail,
                subject: Feedback.subject(kind, appName: "Lelvo"),
                body: draftBody,
                attachment: log
            )
            return
        }
        #endif
        guard let mailURL else { copyAddress(); return }
        PlatformActions.open(mailURL) { opened in
            if !opened { copyAddress(noMailApp: true); return }
            if kind == .bug { offerLogShare(toast: "Attach Lelvo-log.txt in the email if it wasn't added automatically.") }
        }
    }

    /// Telegram doesn't let an app type into a group: the report goes on the clipboard and the topic opens to paste in.
    /// For bugs, the share sheet also offers the redacted log so they can attach it with the paperclip.
    private func postInGroup() {
        PlatformActions.copy(Feedback.groupPost(kind, appName: "Lelvo", env: env))
        if kind == .bug {
            ToastCenter.shared.show(.info, "Report copied. Paste it in the group, then attach the log file.")
            offerLogShare(toast: nil)
        } else {
            ToastCenter.shared.show(.info, "Idea copied. Paste it in the group and send.")
        }
        PlatformActions.open(kind == .bug ? AppLinks.communityBugs : AppLinks.communityIdeas)
    }

    private func offerLogShare(toast: String?) {
        guard let url = AppLog.shared.exportFile() else {
            if let toast { ToastCenter.shared.show(.info, toast) }
            return
        }
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if let toast { ToastCenter.shared.show(.info, toast) }
        #else
        share = ShareItems(urls: [url])
        if let toast { ToastCenter.shared.show(.info, toast) }
        #endif
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
                    Label("Your log file (attached when you email or post)", systemImage: "doc.text.magnifyingglass")
                    NavigationLink { LogsView() } label: { Label("Preview or share logs yourself", systemImage: "eye") }
                case .idea:
                    Label("What you'd like Lelvo to do", systemImage: "lightbulb")
                    Label("Why it would help you", systemImage: "heart")
                    Label("A screenshot or sketch, if it helps", systemImage: "photo")
                }
            } header: {
                Text(kind == .bug ? "What helps me fix it" : "What helps")
            } footer: {
                if kind == .bug {
                    Text("\(Feedback.logHelpNote) \(Feedback.logPrivacyNote)")
                }
            }

            Section {
                Button(action: postInGroup) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Post in the Lelvo group")
                            Text(kind == .bug
                                 ? "Copies your report, opens Bugs in Telegram, and shares the log to attach."
                                 : "Opens Feature ideas in Telegram with your idea copied. Paste it there.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                }
                Button(action: email) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Email \(AppLinks.developerName)")
                            Text(kind == .bug
                                 ? "\(AppLinks.developerEmail). Includes the log when Mail can attach files."
                                 : AppLinks.developerEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
        #if os(iOS)
        .sheet(item: $share) { ActivityView(items: $0.urls) }
        .sheet(item: $mailDraft) { draft in
            MailComposeView(draft: draft) { mailDraft = nil }
        }
        #endif
    }
}

#if os(iOS)
/// Draft for the system Mail composer so a bug report can carry `Lelvo-log.txt` as a real attachment.
struct MailDraft: Identifiable {
    let id = UUID()
    let to: String
    let subject: String
    let body: String
    let attachment: URL?
}

struct MailComposeView: UIViewControllerRepresentable {
    let draft: MailDraft
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([draft.to])
        vc.setSubject(draft.subject)
        vc.setMessageBody(draft.body, isHTML: false)
        if let attachment = draft.attachment, let data = try? Data(contentsOf: attachment) {
            vc.addAttachmentData(data, mimeType: "text/plain", fileName: "Lelvo-log.txt")
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
            onFinish()
        }
    }
}

#endif

extension Bundle {
    /// "0.1.0 (12)": the marketing version and the build number, as About shows them.
    var displayVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
