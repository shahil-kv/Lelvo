import SwiftUI
import Photos
import CloudGalleryCore

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Equatable { case welcome, credentials, phone, code, password, otherDevice, noAccount, library, unlock, scanning, photos }

    @Published var step: Step = .welcome
    @Published var apiId = ""
    @Published var apiHash = ""
    @Published var phone = ""
    /// Phone entry is split like Telegram/WhatsApp: country code + national number.
    @Published var dialCode = Countries.defaultDialCode
    @Published var nationalNumber = ""
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
        // Any new state from Telegram means the previous request finished: never leave the spinner on.
        if auth != .starting { busy = false; credentialsTimeout?.cancel() }
        switch auth {
        case .needsCredentials: if step != .credentials { step = .credentials }
        case .starting, .loggingOut, .closed: break
        case .waitPhone: step = .phone
        case .waitCode(let info): codeInfo = info; step = .code
        case .waitPassword(let hint): passwordHint = hint; step = .password
        case .waitOtherDevice(let link): otherDeviceLink = link; step = .otherDevice
        case .waitEmail: error = "Telegram asks for an email login on this account. Sign in once in the official Telegram app, then try again."
        case .waitRegistration: step = .noAccount
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
        error = nil
        busy = true
        env.td.start()
        // If Telegram doesn't answer (wrong keys, no network), show a message instead of spinning forever.
        credentialsTimeout?.cancel()
        credentialsTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, !Task.isCancelled, self.busy, self.step == .credentials else { return }
            self.busy = false
            self.error = "Telegram didn't respond. Check your internet connection and that api_id / api_hash are copied exactly from my.telegram.org, then try again."
        }
    }

    private var credentialsTimeout: Task<Void, Never>?

    var fullPhone: String { "+" + dialCode.filter(\.isNumber) + nationalNumber.filter(\.isNumber) }
    /// Valid when the number has the right length for the country (India: 10 digits).
    var phoneIsValid: Bool {
        !dialCode.filter(\.isNumber).isEmpty && Countries.lengths(forDialCode: dialCode).contains(nationalNumber.filter(\.isNumber).count)
    }

    func submitPhone() {
        phone = fullPhone
        run { try await self.env.td.submitPhone(self.fullPhone) }
    }

    /// Steps with a back button, like every sign-in flow people know.
    var canGoBack: Bool { [.credentials, .phone, .code, .password, .otherDevice, .noAccount, .unlock].contains(step) }

    func back() {
        error = nil
        info = nil
        switch step {
        case .credentials, .phone: step = .welcome
        case .code, .password, .otherDevice: useDifferentAccount(keepNumber: true)
        case .noAccount: useDifferentAccount()
        case .unlock:
            env.library.forget()
            passphrase = ""
            goToLibrary()
        default: break
        }
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

    /// Sign out and log in with another phone number (keeps the API keys).
    func useDifferentAccount(keepNumber: Bool = false) {
        error = nil
        info = nil
        busy = true
        if !keepNumber { nationalNumber = "" }
        phone = ""
        code = ""
        password = ""
        channels = []
        env.library.forget()
        Task {
            await env.td.switchAccount()
            step = .phone
            busy = false
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
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch m.step {
                case .welcome: WelcomeScreen { m.start() }
                case .credentials: credentials
                case .phone: PhoneScreen(m: m)
                case .code: CodeScreen(m: m)
                case .password: password
                case .otherDevice: otherDevice
                case .noAccount: noAccount
                case .library: library
                case .unlock: unlock
                case .scanning: scanning
                case .photos: photos
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.spring(duration: 0.45, bounce: 0.1), value: m.step)
        .preferredColorScheme(.dark)
    }

    // MARK: - Steps

    private var credentials: some View {
        OnboardingPage(icon: "key.fill", title: "Connect to Telegram",
                       subtitle: "Telegram needs a free API key for apps like this one. It takes a minute and stays on this iPhone.",
                       m: m, button: .init(title: "Continue", enabled: !m.apiId.isEmpty && !m.apiHash.isEmpty) { m.saveCredentials() }) {
            VStack(alignment: .leading, spacing: 14) {
                numbered(1, "Open **my.telegram.org** and log in.")
                numbered(2, "Tap **API development tools** and create an app (any name, platform iOS).")
                numbered(3, "Paste **api_id** and **api_hash** below.")
                Link(destination: .literal("https://my.telegram.org/apps")) {
                    Label("Open my.telegram.org", systemImage: "safari").font(.subheadline.weight(.semibold))
                }
                OnboardingField(placeholder: "api_id", text: $m.apiId, keyboard: .numberPad)
                OnboardingField(placeholder: "api_hash", text: $m.apiHash, secure: true)
            }
        }
    }

    private var password: some View {
        OnboardingPage(icon: "lock.fill", title: "Two-step verification",
                       subtitle: "Your account is protected with an extra password.",
                       m: m, button: .init(title: "Continue", enabled: !m.password.isEmpty) { m.submitPassword() }) {
            VStack(alignment: .leading, spacing: 10) {
                OnboardingField(placeholder: "Password", text: $m.password, secure: true, content: .password, autofocus: true) {
                    if !m.password.isEmpty { m.submitPassword() }
                }
                if !m.passwordHint.isEmpty {
                    Text("Hint: \(m.passwordHint)").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var otherDevice: some View {
        OnboardingPage(icon: "iphone.and.arrow.forward", title: "Confirm on another device",
                       subtitle: "Open Telegram on a device where you're signed in and approve this login.", m: m) {
            Text(m.otherDeviceLink).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var noAccount: some View {
        OnboardingPage(icon: "person.crop.circle.badge.questionmark", title: "No Telegram account",
                       subtitle: "\(m.phone) isn't registered on Telegram yet. Create an account in the Telegram app (it's free), then come back and sign in.",
                       m: m, button: .init(title: "Get Telegram", enabled: true) {
                           if let url = URL(string: "https://apps.apple.com/app/telegram-messenger/id686449807") { UIApplication.shared.open(url) }
                       }) {
            Button { m.back() } label: {
                Label("Use a different number", systemImage: "arrow.uturn.backward").font(.subheadline.weight(.semibold))
            }
        }
    }

    private var library: some View {
        OnboardingPage(icon: "photo.stack.fill", title: "Your library",
                       subtitle: "Everything lives in one private Telegram channel that only you can see.", m: m) {
            VStack(alignment: .leading, spacing: 22) {
                let libraries = m.channels.filter(\.isLibrary)
                let others = m.channels.filter { !$0.isLibrary }
                if m.loadingChannels {
                    HStack(spacing: 10) { ProgressView(); Text("Looking for your library…").foregroundStyle(.secondary) }
                }
                if !libraries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("Restore")
                        ForEach(libraries) { c in
                            channelRow(c, icon: "arrow.clockwise.icloud.fill", subtitle: "Your CloudGallery library", highlight: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel(libraries.isEmpty ? "Start fresh" : "Or start a new one")
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $m.newLibraryEncrypted) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("End-to-end encryption").font(.subheadline.weight(.semibold))
                                Text(m.newLibraryEncrypted ? "Only CloudGallery can open your files." : "Files can also be opened in Telegram.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if m.newLibraryEncrypted {
                            OnboardingField(placeholder: "Passphrase (10+ characters)", text: $m.passphrase, secure: true, content: .newPassword)
                            OnboardingField(placeholder: "Repeat passphrase", text: $m.passphraseConfirm, secure: true, content: .newPassword)
                            Toggle(isOn: $m.acknowledgedRisk) {
                                Text("I understand a lost passphrase means lost photos.").font(.caption).foregroundStyle(.orange)
                            }
                            if let p = m.newPassphraseProblem, !m.passphrase.isEmpty { Text(p).font(.caption).foregroundStyle(.secondary) }
                        }
                        Button { m.createLibrary() } label: {
                            Label("Create “\(LibraryService.titleDefault)”", systemImage: "plus")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(m.busy || m.newPassphraseProblem != nil)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("Use one of your channels")
                        ForEach(others) { c in channelRow(c, icon: "megaphone.fill", subtitle: "Turn it into your library", highlight: false) }
                    }
                }
                HStack {
                    Button("Refresh") { m.loadChannels() }
                    Spacer()
                    Button("Use a different account") { m.useDifferentAccount() }
                }
                .font(.footnote.weight(.medium))
                .disabled(m.busy)
            }
        }
    }

    private var unlock: some View {
        OnboardingPage(icon: "lock.shield.fill", title: "Unlock your library",
                       subtitle: "This library is end-to-end encrypted. Enter its passphrase.",
                       m: m, button: .init(title: "Unlock", enabled: !m.passphrase.isEmpty) { m.unlock() }) {
            OnboardingField(placeholder: "Passphrase", text: $m.passphrase, secure: true, content: .password, autofocus: true) {
                if !m.passphrase.isEmpty { m.unlock() }
            }
        }
    }

    private var scanning: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 140, height: 140)
                    .phaseAnimator([false, true]) { v, on in v.scaleEffect(on ? 1.12 : 0.92).opacity(on ? 0.5 : 1) }
                        animation: { _ in .easeInOut(duration: 1.1) }
                Image(systemName: "arrow.clockwise.icloud.fill").font(.system(size: 56)).foregroundStyle(.tint)
                    .symbolEffect(.pulse)
            }
            Text("Restoring your library").font(.title2.bold())
            Text("\(m.scanned) files found").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                .contentTransition(.numericText()).animation(.default, value: m.scanned)
            if let error = m.error { ErrorBanner(message: error).padding(.horizontal, 24) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var photos: some View {
        let status = m.photoStatus
        let decided = status != .notDetermined
        return OnboardingPage(icon: "photo.on.rectangle.angled", title: "Back up your photos",
                              subtitle: m.info.map { "\($0) Allow Full Access so everything on this iPhone is backed up too." }
                                ?? "Allow Full Access so everything on this iPhone is backed up.",
                              m: m, showsInfo: false,
                              button: decided ? .init(title: "Start using CloudGallery", enabled: true) { app.finishOnboarding() }
                                              : .init(title: "Allow Access", enabled: true) { m.requestPhotos() }) {
            VStack(alignment: .leading, spacing: 12) {
                switch status {
                case .authorized: Label("Full access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .limited: Label("Limited access: only the photos you picked are backed up.", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .denied, .restricted:
                    Label("No access. You can still browse your cloud library.", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                default:
                    feature("checkmark.icloud.fill", "Originals, bit for bit", "Full-quality photos and videos, any size.")
                    feature("play.circle.fill", "Stream from the cloud", "Watch backed-up videos without downloading them.")
                    feature("arrow.triangle.2.circlepath", "Comes back anywhere", "Reinstall or switch phones and it's all still there.")
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: - Pieces

    private func numbered(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.subheadline.bold()).frame(width: 26, height: 26).background(Color.accentColor.opacity(0.2), in: Circle())
            Text(text).font(.subheadline)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func channelRow(_ c: LibraryService.ChannelChoice, icon: String, subtitle: String, highlight: Bool) -> some View {
        Button { m.choose(c) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(highlight ? .white : .accentColor)
                    .frame(width: 44, height: 44)
                    .background(highlight ? Color.accentColor : Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if m.busy { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .padding(14)
            .background(Color.white.opacity(highlight ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(m.busy)
    }
}

// MARK: - Shared page layout

/// Every step: back button, icon, big title, subtitle, content, and one primary button above the keyboard.
private struct OnboardingPage<Content: View>: View {
    struct PrimaryButton { let title: String; let enabled: Bool; let run: () -> Void }

    let icon: String
    let title: String
    let subtitle: String
    @ObservedObject var m: OnboardingModel
    var showsInfo = true
    var button: PrimaryButton? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if m.canGoBack {
                    Button { Haptics.tap(); m.back() } label: {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                            .frame(width: 40, height: 40).background(Color.white.opacity(0.1), in: Circle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Back")
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(.tint)
                            .frame(width: 64, height: 64)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityHidden(true)
                        Text(title).font(.system(size: 32, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    content
                    if let error = m.error { ErrorBanner(message: error) }
                    if showsInfo, let info = m.info { Label(info, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            if let button {
                PrimaryCapsuleButton(title: button.title, enabled: button.enabled, busy: m.busy, action: button.run)
                    .padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
    }
}

/// Large white capsule, like the primary buttons in Apple's and Telegram's onboarding.
struct PrimaryCapsuleButton: View {
    let title: String
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(.black) }
            }
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: 520)
            .frame(height: 54)
            .background(Color.white.opacity(enabled ? 1 : 0.35), in: Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled || busy)
        .frame(maxWidth: .infinity)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

private struct OnboardingField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var secure = false
    var content: UITextContentType? = nil
    var autofocus = false
    var onSubmit: () -> Void = {}
    @State private var revealed = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Group {
                if secure && !revealed { SecureField(placeholder, text: $text) }
                else { TextField(placeholder, text: $text).keyboardType(keyboard) }
            }
            .textContentType(content)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($focused)
            .onSubmit(onSubmit)
            if secure {
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                    .accessibilityLabel(revealed ? "Hide" : "Show")
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? Color.accentColor : .clear, lineWidth: 1.5))
        .onAppear { if autofocus { focused = true } }
    }
}

// MARK: - Welcome

private struct WelcomeScreen: View {
    let start: () -> Void
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            PhotoWall()
                .ignoresSafeArea()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.28),
                                             .init(color: .clear, location: 0.6)], startPoint: .top, endPoint: .bottom))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 18) {
                Text("All your photos.\nIn your own Telegram.")
                    .font(.system(size: 38, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Back up originals, stream videos, and get everything back on any iPhone. Free, private, no servers.")
                    .font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryCapsuleButton(title: "Continue with Telegram", action: start)
                    .padding(.top, 10)
                Label("Stored in a private channel only you can see.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: 560)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 24)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.8).delay(0.15)) { appeared = true } }
    }
}

/// Slowly drifting columns of photo-like tiles (no photo access needed yet).
private struct PhotoWall: View {
    private static let palettes: [[Color]] = [
        [.orange, .pink], [.teal, .blue], [.green, .teal], [.purple, .indigo], [.yellow, .orange],
        [.pink, .red], [.cyan, .blue], [.indigo, .black], [.mint, .green], [.red, .orange], [.blue, .purple], [.brown, .orange]
    ]
    private static let glyphs = ["", "play.fill", "", "livephoto", "", "", "heart.fill", "", "play.fill", "", "", "livephoto"]

    var body: some View {
        GeometryReader { geo in
            let columns = 5
            let width = (geo.size.width * 1.3 - CGFloat(columns - 1) * 8) / CGFloat(columns)
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<columns, id: \.self) { col in
                        column(col, width: width, time: t)
                    }
                }
                .frame(width: geo.size.width * 1.3)
                .rotationEffect(.degrees(-8))
                .offset(x: -geo.size.width * 0.15, y: -60)
            }
        }
    }

    private func column(_ col: Int, width: CGFloat, time: TimeInterval) -> some View {
        let heights: [CGFloat] = (0..<8).map { i in width * [1.0, 1.35, 0.8, 1.2, 1.0, 1.5, 0.9, 1.25][(i + col * 3) % 8] }
        let loop = heights.reduce(0) { $0 + $1 + 8 }
        let speed = [14.0, 20.0, 11.0, 17.0, 13.0][col % 5]
        let offset = -CGFloat((time * speed).truncatingRemainder(dividingBy: Double(loop)))
        return VStack(spacing: 8) {
            ForEach(0..<16, id: \.self) { i in
                tile(index: i % 8 + col * 5, height: heights[i % 8], width: width)
            }
        }
        .offset(y: offset)
    }

    private func tile(index: Int, height: CGFloat, width: CGFloat) -> some View {
        let colors = Self.palettes[index % Self.palettes.count]
        let glyph = Self.glyphs[index % Self.glyphs.count]
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .topLeading) {
                Circle().fill(.white.opacity(0.25)).frame(width: width * 0.35).blur(radius: 18).offset(x: width * 0.15, y: height * 0.12)
            }
            .overlay(alignment: .bottomLeading) {
                if !glyph.isEmpty { Image(systemName: glyph).font(.caption.bold()).foregroundStyle(.white.opacity(0.9)).padding(10) }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Phone

private struct PhoneScreen: View {
    @ObservedObject var m: OnboardingModel
    @FocusState private var numberFocused: Bool
    @State private var pickingCountry = false

    private var country: Countries.Country? { Countries.byDialCode(m.dialCode) }

    var body: some View {
        OnboardingPage(icon: "phone.fill", title: "Your phone number",
                       subtitle: "Use the number of your Telegram account. We'll send a code to your Telegram app.",
                       m: m, button: .init(title: "Continue", enabled: m.phoneIsValid) { m.submitPhone() }) {
            VStack(spacing: 0) {
                Button { pickingCountry = true } label: {
                    HStack {
                        Text(country.map { "\($0.flag)  \($0.name)" } ?? "Choose a country").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.white.opacity(0.1))
                HStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Text("+").foregroundStyle(.secondary)
                        TextField("", text: $m.dialCode)
                            .keyboardType(.numberPad)
                            .frame(width: 48)
                            .onChange(of: m.dialCode) { _, v in
                                let digits = String(v.filter(\.isNumber).prefix(4))
                                if digits != v { m.dialCode = digits }
                            }
                    }
                    .padding(.horizontal, 16)
                    Divider().frame(height: 30).overlay(Color.white.opacity(0.15))
                    TextField("Phone number", text: $m.nationalNumber)
                        .keyboardType(.numberPad)
                        .textContentType(.telephoneNumber)
                        .focused($numberFocused)
                        .padding(.horizontal, 16)
                        .onChange(of: m.nationalNumber) { _, v in
                            // Autofill gives the whole number with the country code: split it.
                            let digits = v.filter(\.isNumber)
                            if v.hasPrefix("+"), let c = Countries.match(prefixOf: digits) {
                                m.dialCode = c.dialCode
                                m.nationalNumber = String(digits.dropFirst(c.dialCode.count))
                            } else if digits.count > Countries.lengths(forDialCode: m.dialCode).upperBound || digits != v {
                                m.nationalNumber = String(digits.prefix(Countries.lengths(forDialCode: m.dialCode).upperBound))
                            }
                        }
                }
                .font(.title3.monospacedDigit())
                .frame(height: 58)
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .onAppear { numberFocused = true }
        .sheet(isPresented: $pickingCountry) {
            CountryPicker { c in m.dialCode = c.dialCode; numberFocused = true }
        }
    }
}

private struct CountryPicker: View {
    let pick: (Countries.Country) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(Countries.all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.dialCode.hasPrefix(query.filter(\.isNumber)) && !query.filter(\.isNumber).isEmpty }) { c in
                Button {
                    pick(c)
                    dismiss()
                } label: {
                    HStack {
                        Text(c.flag)
                        Text(c.name).foregroundStyle(.primary)
                        Spacer()
                        Text("+\(c.dialCode)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Country or code")
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Code

private struct CodeScreen: View {
    @ObservedObject var m: OnboardingModel
    @FocusState private var focused: Bool
    @State private var shake = 0
    private let length = 5

    var body: some View {
        OnboardingPage(icon: "message.fill", title: "Enter the code",
                       subtitle: m.codeInfo.isEmpty ? "We sent a code to your Telegram app." : m.codeInfo,
                       m: m, button: .init(title: "Continue", enabled: m.code.count >= length) { m.submitCode() }) {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    TextField("", text: $m.code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .opacity(0.02)
                        .onChange(of: m.code) { _, v in
                            let digits = String(v.filter(\.isNumber).prefix(length))
                            if digits != v { m.code = digits }
                            if digits.count == length && !m.busy { m.submitCode() }
                        }
                    HStack(spacing: 10) {
                        ForEach(0..<length, id: \.self) { i in
                            let chars = Array(m.code)
                            let current = i == chars.count && focused
                            Text(i < chars.count ? String(chars[i]) : "")
                                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                                .frame(maxWidth: .infinity).frame(height: 62)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(current ? Color.accentColor : (m.error != nil ? .red.opacity(0.7) : .clear), lineWidth: 1.5))
                                .animation(.spring(duration: 0.2), value: m.code)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
                .modifier(Shake(trigger: shake))
                Button {
                    m.back()
                } label: {
                    Text("Wrong number? ").foregroundStyle(.secondary) + Text(m.phone).foregroundStyle(.tint)
                }
                .font(.subheadline)
            }
        }
        .onAppear { focused = true }
        .onChange(of: m.error) { _, e in
            if e != nil { withAnimation(.default) { shake += 1 }; m.code = "" }
        }
    }
}

private struct Shake: GeometryEffect {
    var trigger: Int
    var animatableData: CGFloat {
        get { CGFloat(trigger) }
        set { progress = newValue }
    }
    private var progress: CGFloat = 0
    init(trigger: Int) { self.trigger = trigger; self.progress = CGFloat(trigger) }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(progress * .pi * 6), y: 0))
    }
}

// MARK: - Countries

enum Countries {
    struct Country: Identifiable, Hashable {
        let region: String
        let dialCode: String
        var id: String { region }
        var name: String { Locale.current.localizedString(forRegionCode: region) ?? region }
        var flag: String {
            region.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
        }
    }

    // Region → calling code (shared codes like +1 and +7 resolve to the first listed region).
    private static let codes: [(String, String)] = [
        ("IN", "91"), ("US", "1"), ("GB", "44"), ("AE", "971"), ("SA", "966"), ("QA", "974"), ("KW", "965"), ("OM", "968"), ("BH", "973"),
        ("PK", "92"), ("BD", "880"), ("LK", "94"), ("NP", "977"), ("MV", "960"), ("AF", "93"), ("CA", "1"), ("AU", "61"), ("NZ", "64"),
        ("DE", "49"), ("FR", "33"), ("IT", "39"), ("ES", "34"), ("PT", "351"), ("NL", "31"), ("BE", "32"), ("CH", "41"), ("AT", "43"),
        ("IE", "353"), ("SE", "46"), ("NO", "47"), ("DK", "45"), ("FI", "358"), ("PL", "48"), ("CZ", "420"), ("SK", "421"), ("HU", "36"),
        ("RO", "40"), ("BG", "359"), ("GR", "30"), ("TR", "90"), ("UA", "380"), ("RU", "7"), ("KZ", "7"), ("BY", "375"), ("RS", "381"),
        ("HR", "385"), ("SI", "386"), ("LT", "370"), ("LV", "371"), ("EE", "372"), ("IL", "972"), ("JO", "962"), ("LB", "961"), ("IQ", "964"),
        ("IR", "98"), ("EG", "20"), ("MA", "212"), ("DZ", "213"), ("TN", "216"), ("NG", "234"), ("GH", "233"), ("KE", "254"), ("ET", "251"),
        ("TZ", "255"), ("UG", "256"), ("ZA", "27"), ("CN", "86"), ("HK", "852"), ("TW", "886"), ("JP", "81"), ("KR", "82"), ("SG", "65"),
        ("MY", "60"), ("ID", "62"), ("TH", "66"), ("VN", "84"), ("PH", "63"), ("MM", "95"), ("KH", "855"), ("UZ", "998"), ("AZ", "994"),
        ("GE", "995"), ("AM", "374"), ("BR", "55"), ("AR", "54"), ("MX", "52"), ("CO", "57"), ("CL", "56"), ("PE", "51"), ("VE", "58"),
        ("EC", "593"), ("UY", "598"), ("PY", "595"), ("BO", "591"), ("CU", "53"), ("DO", "1"), ("JM", "1"), ("PR", "1")
    ]

    static let all: [Country] = codes.map { Country(region: $0.0, dialCode: $0.1) }.sorted { $0.name < $1.name }

    static func byDialCode(_ code: String) -> Country? {
        guard let r = codes.first(where: { $0.1 == code }) else { return nil }
        return Country(region: r.0, dialCode: r.1)
    }

    /// Longest calling code that prefixes `digits` (for autofilled "+91…" numbers).
    static func match(prefixOf digits: String) -> Country? {
        codes.filter { digits.hasPrefix($0.1) }.max { $0.1.count < $1.1.count }.map { Country(region: $0.0, dialCode: $0.1) }
    }

    /// National number lengths (without the country code) for common countries; others accept 6–15 digits.
    private static let nationalLengths: [String: ClosedRange<Int>] = [
        "91": 10...10, "1": 10...10, "44": 10...10, "971": 9...9, "966": 9...9, "974": 8...8, "965": 8...8, "968": 8...8,
        "973": 8...8, "92": 10...10, "880": 10...10, "94": 9...9, "977": 10...10, "960": 7...7, "61": 9...9, "64": 8...10,
        "49": 10...11, "33": 9...9, "39": 9...10, "34": 9...9, "351": 9...9, "31": 9...9, "32": 9...9, "41": 9...9,
        "353": 9...9, "46": 9...9, "47": 8...8, "45": 8...8, "48": 9...9, "90": 10...10, "380": 9...9, "7": 10...10,
        "972": 9...9, "20": 10...10, "234": 10...10, "254": 9...9, "27": 9...9, "86": 11...11, "81": 10...10,
        "82": 9...10, "65": 8...8, "60": 9...10, "62": 9...12, "66": 9...9, "84": 9...10, "63": 10...10, "55": 10...11,
        "52": 10...10, "54": 10...10, "57": 10...10
    ]

    static func lengths(forDialCode code: String) -> ClosedRange<Int> { nationalLengths[code] ?? 6...15 }

    static var defaultDialCode: String {
        let region = Locale.current.region?.identifier ?? "IN"
        return codes.first { $0.0 == region }?.1 ?? "91"
    }
}
