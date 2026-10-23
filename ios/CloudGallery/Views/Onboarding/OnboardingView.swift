import SwiftUI
import Photos
import CloudGalleryCore

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Equatable { case welcome, credentials, phone, code, password, otherDevice, library, unlock, scanning, photos }

    @Published var step: Step = .welcome
    @Published var apiId = ""
    @Published var apiHash = ""
    @Published var phone = ""
    @Published var code = ""
    @Published var password = ""
    @Published var codeInfo = ""
    @Published var passwordHint = ""
    @Published var otherDeviceLink = ""
    @Published var channels: [LibraryService.ChannelChoice] = []
    @Published var loadingChannels = false
    @Published var newLibraryEncrypted = false
    @Published var passphrase = ""
    @Published var passphraseConfirm = ""
    @Published var acknowledgedRisk = false
    @Published var scanned = 0
    @Published var busy = false
    @Published var error: String?
    @Published var info: String?
    @Published var photoStatus = PhotoLibraryService.authorizationStatus

    private let env = AppEnvironment.shared
    private var observer: UUID?

    init() {
        if let creds = TDCredentials.load() {
            apiId = String(creds.apiId)
            apiHash = creds.apiHash
        }
        observer = env.td.observeAuth { [weak self] step in
            Task { @MainActor in self?.apply(step) }
        }
    }

    deinit {
        if let observer { TDService.shared.removeObserver(observer) }
    }

    private func apply(_ auth: TDService.AuthStep) {
        guard step != .welcome || auth == .ready else { return }
        switch auth {
        case .needsCredentials: if step != .credentials { step = .credentials }
        case .starting, .loggingOut, .closed: break
        case .waitPhone: step = .phone
        case .waitCode(let info): codeInfo = info; step = .code
        case .waitPassword(let hint): passwordHint = hint; step = .password
        case .waitOtherDevice(let link): otherDeviceLink = link; step = .otherDevice
        case .waitEmail: error = "Telegram asks for an email login on this account. Sign in once in the official Telegram app, then try again."
        case .waitRegistration: error = "This phone number has no Telegram account yet. Create one in the Telegram app first."
        case .ready:
            busy = false
            if [.welcome, .credentials, .phone, .code, .password, .otherDevice].contains(step) { goToLibrary() }
        }
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

    func start() {
        if env.td.isReady { goToLibrary() } else if TDCredentials.load() != nil { step = .phone; env.td.start() } else { step = .credentials }
    }

    func saveCredentials() {
        guard let id = Int(apiId.trimmingCharacters(in: .whitespaces)), id > 0,
              apiHash.trimmingCharacters(in: .whitespaces).count == 32 else {
            error = "api_id is a number and api_hash is 32 characters. Copy both from my.telegram.org → API development tools."
            return
        }
        TDCredentials.save(apiId: id, apiHash: apiHash.trimmingCharacters(in: .whitespaces))
        busy = true
        env.td.start()
    }

    func submitPhone() {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        run { try await self.env.td.submitPhone(digits) }
    }

    func submitCode() { run { try await self.env.td.submitCode(self.code.filter(\.isNumber)) } }
    func submitPassword() { run { try await self.env.td.submitPassword(self.password) } }

    func goToLibrary() {
        if env.library.isConfigured {
            step = env.library.isUnlocked ? .scanning : .unlock
            if step == .scanning { scan() }
            return
        }
        step = .library
        loadChannels()
    }

    func loadChannels() {
        loadingChannels = true
        Task {
            do { channels = try await env.library.candidateChannels() } catch { self.error = error.localizedDescription }
            loadingChannels = false
        }
    }

    var newPassphraseProblem: String? {
        guard newLibraryEncrypted else { return nil }
        if passphrase.count < 10 { return "Use at least 10 characters. A few random words work well." }
        if passphrase != passphraseConfirm { return "The passphrases don't match." }
        if !acknowledgedRisk { return "Confirm you understand a lost passphrase means lost photos." }
        return nil
    }

    func createLibrary() {
        run {
            try await self.env.library.createLibrary(passphrase: self.newLibraryEncrypted ? self.passphrase : nil)
            Haptics.success()
            self.step = .photos
        }
    }

    func choose(_ channel: LibraryService.ChannelChoice) {
        run {
            let header = try await self.env.library.useExisting(chatId: channel.id)
            if header.encrypted { self.step = .unlock } else { self.step = .scanning; self.scan() }
        }
    }

    func unlock() {
        run {
            try self.env.library.unlock(passphrase: self.passphrase)
            self.step = .scanning
            self.scan()
        }
    }

    func scan() {
        run {
            let summary = try await self.env.library.scan(full: true) { n in
                Task { @MainActor in self.scanned = n }
            }
            self.info = summary.items == 0 ? "Your library is empty: a fresh start." : "Found \(summary.items) items in your library."
            self.step = .photos
        }
    }

    func requestPhotos() {
        Task { photoStatus = await PhotoLibraryService.requestAuthorization() }
    }
}

struct OnboardingView: View {
    @StateObject private var m = OnboardingModel()
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
            .safeAreaInset(edge: .bottom) { footer }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var title: String {
        switch m.step {
        case .welcome: return "Welcome"
        case .credentials: return "Telegram API key"
        case .phone: return "Sign in"
        case .code: return "Login code"
        case .password: return "Two-step password"
        case .otherDevice: return "Confirm login"
        case .library: return "Your library"
        case .unlock: return "Unlock library"
        case .scanning: return "Restoring"
        case .photos: return "Photos access"
        }
    }

    @ViewBuilder private var content: some View {
        switch m.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "photo.stack.fill").font(.system(size: 64)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Your photos, in your own Telegram").font(.title.bold())
                Text("CloudGallery backs up original photos and videos, bit for bit, to a private channel in your own Telegram account. No servers, no tracking.")
                bullet("film.stack", "Videos of any size: 4K, HDR, Dolby Vision, ProRes. Big files are split automatically.")
                bullet("play.circle", "Stream videos without downloading them")
                bullet("arrow.counterclockwise.icloud", "Reinstall or switch phones and your library comes back")
                bullet("lock.shield", "Optional end-to-end encryption")
            }
        case .credentials:
            VStack(alignment: .leading, spacing: 12) {
                Text("Telegram requires every app to use an API key. You create your own; it stays on this iPhone.")
                step(1, "Open **my.telegram.org** and log in with your phone number.")
                step(2, "Tap **API development tools** and create an app (any name, e.g. “CloudGallery”, platform iOS).")
                step(3, "Copy **App api_id** (a number) and **App api_hash** (32 characters) here.")
                Link(destination: .literal("https://my.telegram.org/apps")) { Label("Open my.telegram.org", systemImage: "safari") }
                    .buttonStyle(.bordered)
                field("api_id", text: $m.apiId, keyboard: .numberPad)
                field("api_hash", text: $m.apiHash, secure: true)
                Text("Stored only in this iPhone's Keychain. Never share them.").font(.footnote).foregroundStyle(.secondary)
            }
        case .phone:
            VStack(alignment: .leading, spacing: 12) {
                Text("Sign in with the Telegram account that will store your library. Telegram sends you a login code.")
                field("Phone number, e.g. +91 98765 43210", text: $m.phone, keyboard: .phonePad, content: .telephoneNumber)
            }
        case .code:
            VStack(alignment: .leading, spacing: 12) {
                Text(m.codeInfo)
                field("Code", text: $m.code, keyboard: .numberPad, content: .oneTimeCode)
            }
        case .password:
            VStack(alignment: .leading, spacing: 12) {
                Text("Your account has two-step verification. Enter its password.")
                field(m.passwordHint.isEmpty ? "Password" : "Password (hint: \(m.passwordHint))", text: $m.password, secure: true, content: .password)
            }
        case .otherDevice:
            VStack(alignment: .leading, spacing: 12) {
                Text("Confirm this login from another device where you're signed in to Telegram.")
                Text(m.otherDeviceLink).font(.footnote.monospaced()).textSelection(.enabled)
            }
        case .library:
            libraryContent
        case .unlock:
            VStack(alignment: .leading, spacing: 12) {
                Text("This library is end-to-end encrypted. Enter its passphrase. It's checked before anything is decrypted.")
                field("Passphrase", text: $m.passphrase, secure: true, content: .password)
            }
        case .scanning:
            VStack(alignment: .leading, spacing: 12) {
                ProgressView()
                Text("Reading your library from Telegram… \(m.scanned) files so far.")
                Text("The channel is the source of truth, so this restores everything after a reinstall.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .photos:
            VStack(alignment: .leading, spacing: 12) {
                Text("Allow **Full Access** to back up your whole library. With limited access only the photos you pick are backed up.")
                switch m.photoStatus {
                case .authorized: Label("Full access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .limited:
                    Label("Limited access: only selected photos will be backed up.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                case .denied, .restricted:
                    Label("Access denied. You can still browse your cloud library. Enable access in Settings to back up.", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                default:
                    Button { m.requestPhotos() } label: { Label("Allow photo access", systemImage: "photo") }.buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Everything is stored in one private channel. Create a new one, or pick an existing CloudGallery library to restore it.")
            GroupBox("Create a new library") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("End-to-end encryption", isOn: $m.newLibraryEncrypted)
                    Text(m.newLibraryEncrypted
                         ? "Photos, videos and their details are encrypted on this iPhone. Telegram can't see them, and they can only be viewed in CloudGallery."
                         : "Files are stored as-is: you can also open them in Telegram. Telegram can see them like any cloud.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if m.newLibraryEncrypted {
                        field("Passphrase (10+ characters)", text: $m.passphrase, secure: true, content: .newPassword)
                        field("Repeat passphrase", text: $m.passphraseConfirm, secure: true, content: .newPassword)
                        Label("If you lose this passphrase, nobody, including you, can ever decrypt your backup.", systemImage: "exclamationmark.octagon.fill")
                            .font(.footnote).foregroundStyle(.red)
                        Toggle("I understand", isOn: $m.acknowledgedRisk)
                        if let p = m.newPassphraseProblem, !m.passphrase.isEmpty { Text(p).font(.footnote).foregroundStyle(.secondary) }
                        Text("Encryption is chosen once per library and can't be changed later.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { m.createLibrary() } label: {
                        Label("Create “\(LibraryService.titleDefault)”", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.busy || m.newPassphraseProblem != nil)
                }
            }
            GroupBox("Or use one of your channels") {
                VStack(alignment: .leading, spacing: 8) {
                    if m.loadingChannels { ProgressView() }
                    if !m.loadingChannels && m.channels.isEmpty {
                        Text("No channels you own were found.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(m.channels) { c in
                        Button { m.choose(c) } label: {
                            HStack {
                                Image(systemName: c.isLibrary ? "photo.stack" : "megaphone")
                                VStack(alignment: .leading) {
                                    Text(c.title).bold()
                                    Text(c.isLibrary ? "CloudGallery library: restore it" : "Any channel can become a library")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(m.busy)
                    }
                    Button("Refresh list") { m.loadChannels() }.font(.footnote)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let action = primaryAction {
            HStack {
                if m.busy { ProgressView().padding(.trailing, 8) }
                Button(action: action.run) { Text(action.title).frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!action.enabled || m.busy)
            }
            .padding()
            .background(.bar)
        }
    }

    private struct PrimaryAction { let title: String; let enabled: Bool; let run: () -> Void }

    private var primaryAction: PrimaryAction? {
        switch m.step {
        case .welcome: return PrimaryAction(title: "Get started", enabled: true) { m.start() }
        case .credentials: return PrimaryAction(title: "Continue", enabled: !m.apiId.isEmpty && !m.apiHash.isEmpty) { m.saveCredentials() }
        case .phone: return PrimaryAction(title: "Send code", enabled: m.phone.filter(\.isNumber).count >= 7) { m.submitPhone() }
        case .code: return PrimaryAction(title: "Sign in", enabled: m.code.filter(\.isNumber).count >= 4) { m.submitCode() }
        case .password: return PrimaryAction(title: "Continue", enabled: !m.password.isEmpty) { m.submitPassword() }
        case .unlock: return PrimaryAction(title: "Unlock", enabled: !m.passphrase.isEmpty) { m.unlock() }
        case .photos: return PrimaryAction(title: "Finish", enabled: m.photoStatus != .notDetermined) { app.finishOnboarding() }
        case .otherDevice, .library, .scanning: return nil
        }
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default, secure: Bool = false,
                       content: UITextContentType? = nil) -> some View {
        Group {
            if secure { SecureField(title, text: text) } else { TextField(title, text: text).keyboardType(keyboard) }
        }
        .textContentType(content)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(title)
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
}
