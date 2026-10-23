import SwiftUI
import Photos
import CloudGalleryCore

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, botFather, channel, token, chat, test, passphrase, photos }

    @Published var step: Step = .welcome
    @Published var token = ""
    @Published var botName: String?
    @Published var chatIdText = ""
    @Published var detectedChats: [TGChat] = []
    @Published var report: BotPermissionReport?
    @Published var chatTitle: String?
    @Published var existingIndexFound = false
    @Published var passphrase = ""
    @Published var passphraseConfirm = ""
    @Published var acknowledgedRisk = false
    @Published var busy = false
    @Published var error: String?
    @Published var info: String?
    @Published var photoStatus = PhotoLibraryService.authorizationStatus

    private var client: TelegramClient? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : TelegramClient(token: t)
    }

    func run(_ work: @escaping () async throws -> Void) {
        error = nil
        info = nil
        busy = true
        Task {
            do { try await work() } catch {
                self.error = error.localizedDescription
                Haptics.error()
            }
            busy = false
        }
    }

    func verifyToken() {
        run { [self] in
            guard let client else { throw TelegramError.api(code: 401, description: "Enter the token from @BotFather") }
            let me = try await client.getMe()
            botName = me.username.map { "@\($0)" } ?? me.firstName
            Haptics.success()
            step = .chat
        }
    }

    func detectChats() {
        run { [self] in
            guard let client else { return }
            let updates = try await client.getUpdates()
            var seen = Set<Int64>()
            detectedChats = updates.compactMap(\.chat).filter { $0.isChannelOrGroup && seen.insert($0.id).inserted }
            if detectedChats.count == 1 { chatIdText = String(detectedChats[0].id) }
            if detectedChats.isEmpty {
                info = "No channel found yet. Add the bot as an admin, post any message in the channel, then tap Detect again."
            }
        }
    }

    func testConnection() {
        run { [self] in
            guard let client else { return }
            let chatId = chatIdText.trimmingCharacters(in: .whitespaces)
            let chat = try await client.getChat(chatId)
            chatTitle = chat.title
            let report = try await client.checkPermissions(chatId: chatId)
            self.report = report
            guard report.isSufficient else {
                Haptics.error()
                return
            }
            existingIndexFound = chat.pinnedMessage?.value.document?.fileName == IndexCodec.pinnedFileName
            KeychainStore.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: .botToken)
            KeychainStore.set(chatId, for: .chatId)
            UserDefaults.standard.set(chat.type, forKey: Prefs.Key.chatType)
            UserDefaults.standard.set(chat.title, forKey: Prefs.Key.chatTitle)
            UserDefaults.standard.set(botName, forKey: Prefs.Key.botUsername)
            Haptics.success()
        }
    }

    var passphraseProblem: String? {
        if passphrase.count < 10 { return "Use at least 10 characters. A few random words work well." }
        if !existingIndexFound && passphrase != passphraseConfirm { return "The passphrases don't match." }
        if !existingIndexFound && !acknowledgedRisk { return "Confirm you understand the passphrase can't be recovered." }
        return nil
    }

    func savePassphrase() {
        run { [self] in
            if existingIndexFound {
                KeychainStore.set(passphrase, for: .passphrase)
                do {
                    let count = try await AppEnvironment.shared.indexSync.restore(passphrase: passphrase)
                    info = "Restored \(count) items from your cloud index."
                } catch {
                    KeychainStore.set(nil as String?, for: .passphrase)
                    throw error
                }
            } else {
                KeychainStore.set(passphrase, for: .passphrase)
                KeychainStore.set(nil as Data?, for: .fileMasterKey)
                _ = AppEnvironment.shared.ensureFileKeySalt()
            }
            Haptics.success()
            step = .photos
        }
    }

    func requestPhotos() {
        Task {
            photoStatus = await PhotoLibraryService.requestAuthorization()
        }
    }
}

struct OnboardingView: View {
    @StateObject private var m = OnboardingModel()
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ProgressView(value: Double(m.step.rawValue), total: Double(OnboardingModel.Step.allCases.count - 1))
                        .accessibilityLabel("Setup step \(m.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
                    content
                    if let error = m.error { ErrorBanner(message: error) }
                    if let info = m.info {
                        Label(info, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(title)
            .toolbar {
                if m.step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            m.error = nil
                            m.step = OnboardingModel.Step(rawValue: m.step.rawValue - 1) ?? .welcome
                        }
                        .disabled(m.busy)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
    }

    private var title: String {
        switch m.step {
        case .welcome: return "Welcome"
        case .botFather: return "Create a bot"
        case .channel: return "Create a channel"
        case .token: return "Bot token"
        case .chat: return "Backup chat"
        case .test: return "Test connection"
        case .passphrase: return m.existingIndexFound ? "Restore" : "Passphrase"
        case .photos: return "Photos access"
        }
    }

    @ViewBuilder private var content: some View {
        switch m.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "photo.stack.fill").font(.system(size: 64)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Back up your photos to your own Telegram").font(.title.bold())
                Text("CloudGallery uploads your original photos and videos, untouched, to a private Telegram channel that only you control. No accounts, no servers, no tracking.")
                bullet("checkmark.seal", "Originals, never compressed (HEIC, HEVC, Live Photos)")
                bullet("lock.shield", "Encrypted index so you can restore after reinstalling")
                bullet("bolt.horizontal", "Runs from Shortcuts automations, even overnight")
                bullet("exclamationmark.triangle", "Version 1 uses the Bot API: files over 50 MB can't be uploaded and files over 20 MB can't be viewed back in the app.")
            }
        case .botFather:
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Open Telegram and start a chat with **@BotFather**.")
                step(2, "Send **/newbot**, choose a name and a username ending in “bot”.")
                step(3, "BotFather replies with a token like `123456789:AAH…`. Copy it. Treat it like a password.")
                Link(destination: URL(string: "https://t.me/BotFather")!) {
                    Label("Open @BotFather", systemImage: "paperplane.fill")
                }
                .buttonStyle(.bordered)
            }
        case .channel:
            VStack(alignment: .leading, spacing: 12) {
                step(1, "In Telegram, create a **New Channel** and make it **Private**. A private supergroup also works.")
                step(2, "Open the channel → Administrators → **Add Admin** → search your bot.")
                step(3, "Give it **Post Messages**, **Edit Messages of Others**, **Delete Messages** and (for groups) **Pin Messages**.")
                step(4, "Post any message in the channel (e.g. “hi”) so the app can find it.")
                Text("Use a chat only for CloudGallery. Don't delete or unpin the pinned index file.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .token:
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste the token from @BotFather. It's stored only in this iPhone's Keychain.")
                SecureField("123456789:AAH…", text: $m.token)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Bot token")
                if let name = m.botName { Label("Connected to \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        case .chat:
            VStack(alignment: .leading, spacing: 12) {
                Text("Find your channel automatically, or enter its ID (it starts with -100).")
                Button { m.detectChats() } label: { Label("Detect chats", systemImage: "magnifyingglass") }
                    .buttonStyle(.bordered).disabled(m.busy)
                ForEach(m.detectedChats, id: \.id) { chat in
                    Button {
                        m.chatIdText = String(chat.id)
                        Haptics.tap()
                    } label: {
                        HStack {
                            Image(systemName: chat.type == "channel" ? "megaphone" : "person.3")
                            VStack(alignment: .leading) {
                                Text(chat.title ?? "Untitled").bold()
                                Text("\(chat.type) · \(String(chat.id))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.chatIdText == String(chat.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                TextField("Chat ID, e.g. -1001234567890", text: $m.chatIdText)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Chat ID")
            }
        case .test:
            VStack(alignment: .leading, spacing: 12) {
                Text("Checks that the bot is an admin of **\(m.chatTitle ?? m.chatIdText)** with the rights CloudGallery needs.")
                Button { m.testConnection() } label: { Label("Test connection", systemImage: "antenna.radiowaves.left.and.right") }
                    .buttonStyle(.bordered).disabled(m.busy)
                if let r = m.report {
                    check("Bot is an administrator", r.isAdmin)
                    check("Can post messages", r.canPost)
                    check("Can delete messages", r.canDelete)
                    check("Can pin messages", r.canPin)
                    if !r.isSufficient {
                        Text("Fix the missing rights in Telegram (channel → Administrators → your bot), then test again.")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if m.existingIndexFound {
                        Label("Found an existing CloudGallery backup in this chat. You can restore it next.", systemImage: "arrow.counterclockwise.icloud")
                            .foregroundStyle(.tint)
                    }
                }
            }
        case .passphrase:
            VStack(alignment: .leading, spacing: 12) {
                if m.existingIndexFound {
                    Text("Enter the passphrase you used before. Your whole gallery will reappear; thumbnails download as you scroll.")
                } else {
                    Text("This passphrase encrypts your cloud index (and your photos, if you turn on end-to-end encryption). You need it to restore after reinstalling.")
                }
                SecureField("Passphrase", text: $m.passphrase)
                    .textContentType(m.existingIndexFound ? .password : .newPassword)
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                if !m.existingIndexFound {
                    SecureField("Repeat passphrase", text: $m.passphraseConfirm)
                        .textContentType(.newPassword)
                        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    Label("If you forget this passphrase, nobody can recover your index or encrypted photos. Store it in a password manager.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.footnote).foregroundStyle(.red)
                    Toggle("I understand it can't be recovered", isOn: $m.acknowledgedRisk)
                }
                if let p = m.passphraseProblem, !m.passphrase.isEmpty {
                    Text(p).font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .photos:
            VStack(alignment: .leading, spacing: 12) {
                Text("CloudGallery needs **Full Access** to back up your whole library. With limited access it can only back up the photos you pick.")
                switch m.photoStatus {
                case .authorized:
                    Label("Full access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .limited:
                    Label("Limited access: only selected photos will be backed up. You can change this in Settings any time.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                case .denied, .restricted:
                    Label("Access denied. Enable it in the Settings app.", systemImage: "xmark.octagon").foregroundStyle(.red)
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                default:
                    Button { m.requestPhotos() } label: { Label("Allow photo access", systemImage: "photo") }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if m.busy { ProgressView().padding(.trailing, 8) }
            Button(action: next) {
                Text(nextTitle).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdvance || m.busy)
        }
        .padding()
        .background(.bar)
    }

    private var nextTitle: String {
        switch m.step {
        case .welcome: return "Get started"
        case .token: return "Verify token"
        case .passphrase: return m.existingIndexFound ? "Restore my gallery" : "Save passphrase"
        case .photos: return "Finish"
        default: return "Continue"
        }
    }

    private var canAdvance: Bool {
        switch m.step {
        case .token: return !m.token.trimmingCharacters(in: .whitespaces).isEmpty
        case .chat: return m.chatIdText.trimmingCharacters(in: .whitespaces).count > 3
        case .test: return m.report?.isSufficient == true
        case .passphrase: return m.passphraseProblem == nil
        case .photos: return m.photoStatus != .notDetermined
        default: return true
        }
    }

    private func next() {
        switch m.step {
        case .token: m.verifyToken()
        case .passphrase: m.savePassphrase()
        case .photos: app.finishOnboarding()
        default:
            m.error = nil
            m.step = OnboardingModel.Step(rawValue: m.step.rawValue + 1) ?? .photos
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(.tint) }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 28, height: 28).background(.tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text(text)
        }
    }

    private func check(_ text: String, _ ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? .green : .red)
    }
}
