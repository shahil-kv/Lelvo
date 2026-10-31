import SwiftUI
import Photos
import LelvoCore

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Equatable { case welcome, credentials, phone, code, password, otherDevice, noAccount, library, unlock, recoveryKey, scanning, photos }

    @Published var step: Step = .welcome
    /// Page of the intro, kept so Back from sign-in returns to where the user left it.
    @Published var introPage = 0
    /// Items found when an existing library was restored, for the welcome-back ending.
    @Published var restoredItems: Int?
    @Published var apiId = ""
    @Published var apiHash = ""
    @Published var phone = ""
    /// Phone entry is split like Telegram/WhatsApp: country code + national number.
    @Published var dialCode = Countries.defaultDialCode
    @Published var nationalNumber = ""
    @Published var code = ""
    @Published var password = ""
    @Published var codeInfo = ""
    /// Digits Telegram sent (5 or 6), or 0 when the code is a word or phrase.
    @Published var codeLength = 5
    @Published var passwordHint = ""
    @Published var otherDeviceLink = ""
    @Published var channels: [LibraryService.ChannelChoice] = []
    @Published var loadingChannels = false
    @Published var newLibraryEncrypted = false
    @Published var passphrase = ""
    @Published var newLibraryName = LibraryService.titleDefault
    @Published var passphraseConfirm = ""
    /// A new encrypted library's recovery key, shown once on its own step.
    @Published var recoveryKey: RecoveryKey?
    @Published var acknowledgedRisk = false
    @Published var scanned = 0
    @Published var busy = false
    @Published var error: String?
    @Published var info: String?
    @Published var photoStatus = PhotoLibraryService.authorizationStatus

    private let env = AppEnvironment.shared
    private var observer: UUID?

    #if DEBUG
    /// Screenshot preview (`-replay N`): the real screens, but nothing is sent to Telegram and no library is created.
    /// 0 plays a new user; more plays a returning user whose library has that many items.
    var replayRestored: Int?
    #endif

    init() {
        #if DEBUG
        // For screenshots: `-introPage N` opens the intro on page N; `-replay N` with `-replayStep library|photos`
        // opens that step of a preview.
        introPage = UserDefaults.standard.integer(forKey: "introPage")
        if let n = UserDefaults.standard.string(forKey: "replay").flatMap(Int.init) {
            self.replayRestored = n
            switch UserDefaults.standard.string(forKey: "replayStep") {
            case "library": step = .library
            case "photos": restoredItems = n; step = .photos
            default: break
            }
        }
        #endif
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
        #if DEBUG
        if replayRestored != nil { return }
        #endif
        guard step != .welcome || auth == .ready else { return }
        // Any new state from Telegram means the previous request finished: never leave the spinner on.
        if auth != .starting { busy = false; credentialsTimeout?.cancel() }
        switch auth {
        case .needsCredentials: if step != .credentials { step = .credentials }
        case .starting, .loggingOut, .closed: break
        case .waitPhone: step = .phone
        case .waitCode(let info, let length): codeInfo = info; codeLength = length; step = .code
        case .waitPassword(let hint): passwordHint = hint; step = .password
        case .waitOtherDevice(let link): otherDeviceLink = link; step = .otherDevice
        case .waitEmail: error = "Telegram asks for an email login on this account. Sign in once in the official Telegram app, then try again."
        case .waitRegistration: step = .noAccount
        case .ready:
            busy = false
            if [.welcome, .credentials, .phone, .code, .password, .otherDevice].contains(step) { goToLibrary() }
        }
    }

    func run(_ label: String = #function, _ work: @escaping () async throws -> Void) {
        error = nil
        info = nil
        busy = true
        let started = Date()
        appLog("Onboarding: \(label) started (step \(step))")
        Task {
            do {
                try await work()
                appLog(String(format: "Onboarding: %@ finished in %.1f s", label, Date().timeIntervalSince(started)))
            } catch let error as TDServiceError where error.keysRejected && TDCredentials.usingBundled {
                // Telegram revoked the built-in keys: carry on with the user's own (free, one minute at my.telegram.org).
                AppLog.shared.error("Onboarding: built-in api_id refused (\(error.localizedDescription)); asking for own keys")
                apiId = ""
                apiHash = ""
                step = .credentials
                self.error = "This version of Lelvo can't connect to Telegram with its built-in key. Add your own free key below to continue. Your photos are safe in your channel."
            } catch {
                AppLog.shared.error(String(format: "Onboarding: %@ failed after %.1f s: %@", label, Date().timeIntervalSince(started), error.localizedDescription))
                self.error = error.localizedDescription
                Haptics.error()
            }
            busy = false
        }
    }

    /// The phone step comes first even without app keys, so the App Review demo number always works;
    /// a real number then asks for keys if the build has none.
    func start() {
        #if DEBUG
        if let n = replayRestored {
            if n > 0 { restoredItems = n; step = .photos } else { step = .library }
            return
        }
        #endif
        if env.td.isReady { goToLibrary(); return }
        step = .phone
        if TDCredentials.load() != nil { env.td.start() }
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
        // Restart rather than start: TDLib may already be running on built-in keys that Telegram refused.
        Task { await env.td.restart() }
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

    /// The App Review number was entered: the code step checks the demo code instead of Telegram's.
    private var demoSignIn = false

    func submitPhone() {
        phone = fullPhone
        if DemoMode.matches(phone: fullPhone) {
            demoSignIn = true
            error = nil
            codeLength = DemoMode.code.count
            codeInfo = "Demo account: enter the code from the App Review notes."
            step = .code
            return
        }
        guard TDCredentials.load() != nil else { step = .credentials; return }
        run { try await self.env.td.submitPhone(self.fullPhone) }
    }

    /// Steps with a back button, like every sign-in flow people know.
    var canGoBack: Bool { [.credentials, .phone, .code, .password, .otherDevice, .noAccount, .unlock].contains(step) }

    func back() {
        error = nil
        info = nil
        switch step {
        case .credentials, .phone: step = .welcome
        case .code where demoSignIn:
            demoSignIn = false
            code = ""
            step = .phone
        case .code, .password, .otherDevice: useDifferentAccount(keepNumber: true)
        case .noAccount: useDifferentAccount()
        case .unlock:
            env.library.forget()
            passphrase = ""
            goToLibrary()
        default: break
        }
    }

    func submitCode() {
        let code = codeLength > 0 ? self.code.filter(\.isNumber) : self.code.trimmingCharacters(in: .whitespacesAndNewlines)
        if demoSignIn {
            guard code == DemoMode.code else {
                error = "That code isn't right. Check the code in the App Review notes."
                Haptics.error()
                return
            }
            DemoMode.enter(store: env.store)
            info = "Demo library: sample photos and videos, nothing is uploaded."
            step = .photos
            return
        }
        run { try await self.env.td.submitCode(code) }
    }
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

    /// Set when the channel search failed or found nothing, so the screen offers a retry before "Create".
    @Published var channelSearchDone = false

    func loadChannels() {
        loadingChannels = true
        channelSearchDone = false
        busy = false
        Task {
            // Right after sign-in Telegram may still be syncing the chat list: retry before concluding there's no library.
            for attempt in 0..<3 {
                do {
                    channels = try await env.library.candidateChannels()
                    error = nil
                    if channels.contains(where: \.isLibrary) || attempt == 2 { break }
                } catch {
                    self.error = error.localizedDescription
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            loadingChannels = false
            channelSearchDone = true
        }
    }

    var newPassphraseProblem: String? {
        EncryptionChoice.problem(encrypted: newLibraryEncrypted, passphrase: passphrase, confirm: passphraseConfirm, acknowledged: acknowledgedRisk)
    }

    func renameLibrary(_ channel: LibraryService.ChannelChoice, to title: String) {
        run {
            try await self.env.library.rename(chatId: channel.id, to: title)
            self.channels = try await self.env.library.candidateChannels()
        }
    }

    func createLibrary() {
        #if DEBUG
        if replayRestored != nil { step = .photos; return }
        #endif
        run {
            let name = self.newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = try await self.env.library.createLibrary(title: name.isEmpty ? LibraryService.titleDefault : String(name.prefix(128)),
                                                                   passphrase: self.newLibraryEncrypted ? self.passphrase : nil)
            Haptics.success()
            if let key = created.recoveryKey {
                self.recoveryKey = key
                self.step = .recoveryKey
            } else {
                self.step = .photos
            }
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
            try await self.env.library.unlock(secret: self.passphrase)
            self.step = .scanning
            self.scan()
        }
    }

    func scan() {
        run {
            let summary = try await self.env.library.scan(full: true) { n in
                Task { @MainActor in self.scanned = n }
            }
            // Link the restored items to the photos already on this device before the grid shows, so those
            // photos never appear as "not backed up" (it otherwise waited for the next app activation).
            let env = self.env
            _ = await Task.detached(priority: .userInitiated) { env.engine.relinkRestoredItems() }.value
            self.info = summary.items == 0 ? "Your library is empty: a fresh start." : "Found \(summary.items) items in your library."
            self.restoredItems = summary.items
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
                case .welcome:
                    IntroView(page: $m.introPage, encrypted: $m.newLibraryEncrypted, photoStatus: $m.photoStatus) { m.start() }
                case .credentials: credentials
                case .phone: PhoneScreen(m: m)
                case .code: CodeScreen(m: m)
                case .password: password
                case .otherDevice: otherDevice
                case .noAccount: noAccount
                case .library: library
                case .unlock: unlock
                case .recoveryKey:
                    if let key = m.recoveryKey {
                        RecoveryKeyView(key: key) {
                            m.recoveryKey = nil
                            m.step = .photos
                        }
                    }
                case .scanning: scanning
                case .photos:
                    if !DemoMode.isActive, m.photoStatus == .authorized || m.photoStatus == .limited {
                        FirstBackupView(restored: m.restoredItems) { app.finishOnboarding() }
                    } else {
                        photos
                    }
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.spring(duration: 0.45, bounce: 0.1), value: m.step)
        // Our fields draw their own rounded background and focus ring; no system bezel inside them.
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .macBorderlessButtons()
        .preferredColorScheme(.dark)
    }

    // MARK: - Steps

    private var credentials: some View {
        OnboardingPage(icon: "key.fill", title: "Connect to Telegram",
                       subtitle: "Telegram needs a free API key for apps like this one. It takes a minute and stays on this \(Device.name).",
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
                           if let url = URL(string: "https://apps.apple.com/app/telegram-messenger/id686449807") { PlatformActions.open(url) }
                       }) {
            Button { m.back() } label: {
                Label("Use a different number", systemImage: "arrow.uturn.backward").font(.subheadline.weight(.semibold))
            }
        }
    }

    private var library: some View { LibraryScreen(m: m) }

    private var unlock: some View {
        OnboardingPage(icon: "lock.shield.fill", title: "Unlock your library",
                       subtitle: "This library is end-to-end encrypted. Enter its passphrase, or its recovery key if you forgot the passphrase.",
                       m: m, button: .init(title: "Unlock", enabled: !m.passphrase.isEmpty) { m.unlock() }) {
            OnboardingField(placeholder: "Passphrase or recovery key", text: $m.passphrase, secure: true, content: .password, autofocus: true) {
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
                              subtitle: DemoMode.isActive
                                ? "\(m.info ?? "") Allowing access shows this \(Device.name)'s photos next to the samples; they stay on the \(Device.name)."
                                : m.info.map { "\($0) Allow Full Access so everything on this \(Device.name) is backed up too." }
                                    ?? "Allow Full Access so everything on this \(Device.name) is backed up.",
                              m: m, showsInfo: false,
                              button: decided ? .init(title: "Start using Lelvo", enabled: true) { app.finishOnboarding() }
                                              : .init(title: "Allow Access", enabled: true) { m.requestPhotos() }) {
            VStack(alignment: .leading, spacing: 12) {
                switch status {
                case .authorized: Label("Full access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .limited: Label("Limited access: only the photos you picked are backed up.", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .denied, .restricted:
                    Label("No access. You can still browse your cloud library.", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Button("Open Settings") { PlatformActions.openPhotoSettings() }
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

}

// MARK: - Library

/// One clear decision: restore the library we found, or create one. Everything else is a secondary link.
private struct LibraryScreen: View {
    @ObservedObject var m: OnboardingModel
    @State private var creating = false
    @State private var pickingChannel = false
    @State private var selectedId: Int64?
    @State private var renaming: LibraryService.ChannelChoice?
    @State private var renameText = ""
    @State private var editingName = false

    private var libraries: [LibraryService.ChannelChoice] { m.channels.filter(\.isLibrary) }
    private var others: [LibraryService.ChannelChoice] { m.channels.filter { !$0.isLibrary } }

    var body: some View {
        Group {
            if m.loadingChannels && m.channels.isEmpty {
                searching
            } else if m.error != nil && m.channels.isEmpty {
                OnboardingPage(icon: "wifi.exclamationmark", title: "Couldn't check your channels",
                               subtitle: "We need to look for an existing library before creating a new one.",
                               m: m, button: .init(title: "Try again", enabled: true) { m.loadChannels() }) {
                    secondaryLinks(showCreate: false)
                }
            } else if !libraries.isEmpty {
                let chosen = libraries.first { $0.id == selectedId } ?? libraries[0]
                OnboardingPage(icon: "checkmark.icloud.fill", title: "Welcome back",
                               subtitle: libraries.count == 1
                                 ? "We found your library in Telegram. Restore it to see everything you've backed up."
                                 : "We found \(libraries.count) libraries in your Telegram. Choose the one to use on this \(Device.name).",
                               m: m, button: .init(title: "Restore “\(chosen.title)”", enabled: true) { m.choose(chosen) }) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(libraries) { c in
                            LibraryCard(title: c.title, encrypted: c.encrypted, selected: c.id == chosen.id,
                                        onRename: { renameText = c.title; renaming = c })
                                .onTapGesture { Haptics.tap(); selectedId = c.id }
                        }
                        secondaryLinks(showCreate: true)
                    }
                }
            } else {
                // First time: one library is made for you. The only real choice is Standard or encrypted.
                OnboardingPage(icon: "photo.stack.fill", title: "Your library",
                               subtitle: "Lelvo makes a private channel in your Telegram for your backup. Only you can see it.",
                               m: m, button: .init(title: m.newLibraryEncrypted ? "Create my encrypted library" : "Create my library",
                                                   enabled: m.newPassphraseProblem == nil && !m.newLibraryName.trimmingCharacters(in: .whitespaces).isEmpty) {
                                   m.createLibrary()
                               }) {
                    VStack(alignment: .leading, spacing: 18) {
                        nameRow
                        EncryptionChoice(encrypted: $m.newLibraryEncrypted, passphrase: $m.passphrase,
                                         confirm: $m.passphraseConfirm, acknowledged: $m.acknowledgedRisk, showsPreview: true)
                        secondaryLinks(showCreate: false)
                    }
                }
            }
        }
        .alert("Rename library", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { if let c = renaming { m.renameLibrary(c, to: renameText) }; renaming = nil }
        } message: { Text("Only the name changes. Your photos stay where they are.") }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("A new, empty library is created next to your current one.").foregroundStyle(.secondary)
                        OnboardingField(placeholder: "Library name", text: $m.newLibraryName)
                        EncryptionChoice(encrypted: $m.newLibraryEncrypted, passphrase: $m.passphrase,
                                         confirm: $m.passphraseConfirm, acknowledged: $m.acknowledgedRisk)
                    }
                    .padding(20)
                }
                .safeAreaInset(edge: .bottom) {
                    PrimaryCapsuleButton(title: "Create library", enabled: m.newPassphraseProblem == nil, busy: m.busy) {
                        creating = false
                        m.createLibrary()
                    }
                    .padding(20)
                }
                .navigationTitle("New library")
                .inlineNavigationTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { creating = false } } }
            }
            .presentationDetents([.large])
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $pickingChannel) {
            NavigationStack {
                List {
                    if !libraries.isEmpty {
                        Section("Lelvo libraries") {
                            ForEach(libraries) { c in channelButton(c, icon: "photo.stack.fill") }
                        }
                    }
                    if !others.isEmpty {
                        Section {
                            ForEach(others) { c in channelButton(c, icon: "megaphone.fill") }
                        } header: { Text("Your channels") } footer: {
                            Text("Any channel you own can become your library.")
                        }
                    }
                    if m.channels.isEmpty { Text("No channels found.").foregroundStyle(.secondary) }
                }
                .navigationTitle("Choose a channel")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingChannel = false } }
                    ToolbarItem(placement: .primaryAction) { Button { m.loadChannels() } label: { Image(systemName: "arrow.clockwise") } }
                }
            }
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
        }
    }

    /// The name is filled in for you; renaming is one tap away and can be done later too.
    @ViewBuilder private var nameRow: some View {
        if editingName {
            OnboardingField(placeholder: "Library name", text: $m.newLibraryName, autofocus: true) { editingName = false }
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    Text(m.newLibraryName).font(.body.weight(.semibold))
                }
                Spacer()
                Button("Rename") { Haptics.tap(); editingName = true }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("You can rename it any time in Settings.").font(.footnote).foregroundStyle(.secondary).padding(.top, -10)
        }
    }

    private var searching: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Looking for your library…").font(.title3.weight(.semibold))
            Text("Checking your Telegram channels").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func secondaryLinks(showCreate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if showCreate {
                Button { creating = true } label: { Label("Start a new library instead", systemImage: "plus.circle") }
            }
            if !others.isEmpty {
                Button { pickingChannel = true } label: { Label("Use one of your other channels", systemImage: "list.bullet") }
            }
            Button { m.useDifferentAccount() } label: { Label("Use a different Telegram account", systemImage: "person.crop.circle") }
        }
        .font(.subheadline.weight(.medium))
        .disabled(m.busy)
        .padding(.top, 4)
    }

    private func channelButton(_ c: LibraryService.ChannelChoice, icon: String) -> some View {
        Button {
            pickingChannel = false
            m.choose(c)
        } label: {
            Label { Text(c.title).foregroundStyle(.primary) } icon: { Image(systemName: icon) }
        }
    }
}

/// A library as a selectable card: name, Standard/Encrypted, and a rename button when selected.
struct LibraryCard: View {
    let title: String
    let encrypted: Bool
    var selected = false
    var badge: String? = nil
    var onRename: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: encrypted ? "lock.shield.fill" : "photo.stack.fill")
                .font(.title3).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: encrypted ? [.purple, .indigo] : [.blue, .indigo],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline).lineLimit(1)
                    if let badge {
                        Text(badge).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.25), in: Capsule()).foregroundStyle(.tint)
                    }
                }
                Label(encrypted ? "End-to-end encrypted" : "Standard · private channel", systemImage: encrypted ? "lock.fill" : "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected, let onRename {
                Button(action: onRename) {
                    Image(systemName: "pencil").font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34).background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(title)")
            }
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .padding(16)
        .background(Color.white.opacity(selected ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Standard vs end-to-end encrypted, as two option cards (onboarding and Settings).
struct EncryptionChoice: View {
    @Binding var encrypted: Bool
    @Binding var passphrase: String
    @Binding var confirm: String
    @Binding var acknowledged: Bool
    /// Shows what the channel in Telegram will look like for the chosen kind.
    var showsPreview = false

    /// Why the encrypted choice isn't ready yet (nil = ready).
    static func problem(encrypted: Bool, passphrase: String, confirm: String, acknowledged: Bool) -> String? {
        guard encrypted else { return nil }
        if passphrase.count < 10 { return "Use at least 10 characters. A few random words work well." }
        if passphrase != confirm { return "The passphrases don't match." }
        if !acknowledged { return "Confirm you understand that losing both the passphrase and the recovery key means losing your photos." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            option(isEncrypted: false, icon: "photo.on.rectangle", title: "Standard",
                   detail: "Fastest. Files can also be opened in the Telegram app.")
            option(isEncrypted: true, icon: "lock.shield.fill", title: "End-to-end encrypted",
                   detail: "Only Lelvo on your devices can open your files.")
            if showsPreview { TelegramPreview(encrypted: encrypted) }
            if encrypted {
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingField(placeholder: "Passphrase (10+ characters)", text: $passphrase, secure: true, content: .newPassword)
                    OnboardingField(placeholder: "Repeat passphrase", text: $confirm, secure: true, content: .newPassword)
                    Toggle(isOn: $acknowledged) {
                        Text("I understand that if I lose both this passphrase and the recovery key I'll get next, nobody can help me get my photos back. Not Lelvo, not Telegram.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let p = Self.problem(encrypted: encrypted, passphrase: passphrase, confirm: confirm, acknowledged: acknowledged),
                       !passphrase.isEmpty {
                        Text(p).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("This choice can't be changed later for this library.").font(.caption).foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(duration: 0.3), value: encrypted)
    }

    private func option(isEncrypted: Bool, icon: String, title: String, detail: String) -> some View {
        let selected = encrypted == isEncrypted
        return Button {
            Haptics.tap()
            encrypted = isEncrypted
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(selected ? .white : .secondary)
                    .frame(width: 42, height: 42)
                    .background(selected ? Color.accentColor : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(16)
            .background(Color.white.opacity(selected ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    // Solid behind the button so fields scrolling under it never show through.
                    .background {
                        Color.black
                            .overlay(alignment: .top) {
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 28).offset(y: -28)
                            }
                            .ignoresSafeArea(edges: .bottom)
                    }
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
            .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.45))
            .frame(maxWidth: 520)
            .frame(height: 54)
            // Solid when disabled too: a see-through button shows whatever scrolls under it.
            .background(enabled ? Color.white : Color(white: 0.2), in: Capsule())
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

struct OnboardingField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: PlatformKeyboard = .default
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
                else { TextField(placeholder, text: $text).platformKeyboard(keyboard) }
            }
            .textContentType(content)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .autocorrectionDisabled()
            .noAutocapitalization()
            .focused($focused)
            .onSubmit(onSubmit)
            .accessibilityLabel(placeholder)
            if secure {
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
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
                            .platformKeyboard(.numberPad)
                            .frame(width: 48)
                            .accessibilityLabel("Country code")
                            .onChange(of: m.dialCode) { _, v in
                                let digits = String(v.filter(\.isNumber).prefix(4))
                                if digits != v { m.dialCode = digits }
                            }
                    }
                    .padding(.horizontal, 16)
                    Divider().frame(height: 30).overlay(Color.white.opacity(0.15))
                    TextField("Phone number", text: $m.nationalNumber)
                        .platformKeyboard(.numberPad)
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
            .platformSearchable(text: $query, prompt: "Country or code")
            .navigationTitle("Country")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - Code

private struct CodeScreen: View {
    @ObservedObject var m: OnboardingModel
    @FocusState private var focused: Bool
    @State private var shake = 0
    /// Digits Telegram sent; 0 when the code is a word or phrase (typed into a plain field instead of boxes).
    private var length: Int { m.codeLength }

    var body: some View {
        OnboardingPage(icon: "message.fill", title: "Enter the code",
                       subtitle: m.codeInfo.isEmpty ? "We sent a code to your Telegram app." : m.codeInfo,
                       m: m, button: .init(title: "Continue", enabled: length > 0 ? m.code.count >= length : !m.code.trimmingCharacters(in: .whitespaces).isEmpty) { m.submitCode() }) {
            VStack(alignment: .leading, spacing: 18) {
                if length > 0 { digitBoxes } else {
                    OnboardingField(placeholder: "Code", text: $m.code, autofocus: true) {
                        if !m.code.isEmpty { m.submitCode() }
                    }
                }
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

    private var digitBoxes: some View {
        ZStack {
            TextField("", text: $m.code)
                .platformKeyboard(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .opacity(0.02)
                .accessibilityLabel("Login code")
                .onChange(of: m.code) { _, v in
                    let digits = String(v.filter(\.isNumber).prefix(length))
                    if digits != v { m.code = digits }
                    if digits.count == length && !m.busy { m.submitCode() }
                }
            HStack(spacing: length > 5 ? 8 : 10) {
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
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .modifier(Shake(trigger: shake))
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
