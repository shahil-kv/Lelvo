import SwiftUI
import LelvoCore

/// Shows a new recovery key once. Nothing in Lelvo or Telegram keeps a readable copy, so the user has to save it now.
struct RecoveryKeyView: View {
    let key: RecoveryKey
    let onDone: () -> Void
    @State private var copied = false

    /// Groups of four, in rows of four: easy to copy onto paper without losing your place.
    private var groups: [String] { key.text.split(separator: "-").map(String.init) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(LinearGradient(colors: [Color(red: 0.43, green: 0.29, blue: 1), Color(red: 0.72, green: 0.61, blue: 1)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Your recovery key").font(.title2.weight(.bold))
                    Text("The only way back into your photos if you forget your passphrase. Keep it in a password manager or on paper.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                VStack(spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            Text(group)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Recovery key")
                    .accessibilityValue(key.text.replacingOccurrences(of: "-", with: " "))
                    Button {
                        PlatformActions.copySecret(key.text)
                        copied = true
                        Haptics.success()
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(copied ? Color.green : Color.primary)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    (Text("Lose both and your photos are gone. ").foregroundStyle(.orange).fontWeight(.semibold)
                     + Text("Nobody can recover them. Not Lelvo, not Telegram."))
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryCapsuleButton(title: "I've saved it") { onDone() }.padding(20)
        }
    }
}

/// Settings for an encrypted library: change the passphrase, make a new recovery key, or add one to a library from
/// before recovery keys (which upgrades its header; the photos in Telegram stay exactly as they are).
struct EncryptionSettingsView: View {
    private enum Sheet: Identifiable {
        case changePassphrase, newRecoveryKey, show(RecoveryKey)
        var id: String {
            switch self {
            case .changePassphrase: return "change"
            case .newRecoveryKey: return "new"
            case .show(let k): return k.text
            }
        }
    }

    @State private var sheet: Sheet?
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var needsUpgrade = AppEnvironment.shared.library.needsHeaderUpgrade
    private var library: LibraryService { AppEnvironment.shared.library }

    var body: some View {
        Form {
            Section {
                if needsUpgrade {
                    Text("This library has no recovery key yet: if you forget its passphrase, your photos can't be opened. Add one now. Your photos in Telegram stay exactly as they are.")
                        .font(.subheadline)
                }
                Button(needsUpgrade ? "Add a Recovery Key" : "New Recovery Key") { open(.newRecoveryKey) }
                Button("Change Passphrase") { open(.changePassphrase) }
            } footer: {
                Text("Your photos are encrypted on your devices. The passphrase or the recovery key opens them on a new device.")
            }
        }
        .navigationTitle("Passphrase and recovery key")
        // What Telegram has now, not a copy saved earlier: decides between "Add" and "New Recovery Key".
        .task { if (try? await library.refreshHeader()) != nil { needsUpgrade = library.needsHeaderUpgrade } }
        .sheet(item: $sheet) { s in
            NavigationStack { content(for: s) }
                .interactiveDismissDisabled(busy || { if case .show = s { return true }; return false }())
        }
    }

    private func open(_ s: Sheet) {
        current = ""; new = ""; confirm = ""; error = nil
        sheet = s
    }

    @ViewBuilder private func content(for s: Sheet) -> some View {
        switch s {
        case .show(let key):
            RecoveryKeyView(key: key) { sheet = nil; needsUpgrade = library.needsHeaderUpgrade }
                .navigationTitle("Recovery key").inlineNavigationTitle()
        case .newRecoveryKey:
            form(title: needsUpgrade ? "Add a Recovery Key" : "New Recovery Key",
                 note: needsUpgrade ? "Enter your passphrase to add a recovery key." : "Enter your passphrase. Your old recovery key will stop working.",
                 ready: !current.isEmpty) {
                OnboardingField(placeholder: "Passphrase", text: $current, secure: true, content: .password, autofocus: true)
            } action: {
                try await library.newRecoveryKey(passphrase: current)
            }
        case .changePassphrase:
            let problem = PassphraseSetup.problem(passphrase: new, confirm: confirm, acknowledged: true)
            form(title: "Change Passphrase",
                 note: needsUpgrade ? "Your library also gets a recovery key." : "Your recovery key keeps working.",
                 ready: !current.isEmpty && problem == nil) {
                OnboardingField(placeholder: "Current passphrase or recovery key", text: $current, secure: true, content: .password, autofocus: true)
                OnboardingField(placeholder: "New passphrase (10+ characters)", text: $new, secure: true, content: .newPassword)
                OnboardingField(placeholder: "Repeat new passphrase", text: $confirm, secure: true, content: .newPassword)
                if let problem, !new.isEmpty { Text(problem).font(.footnote).foregroundStyle(.secondary) }
            } action: {
                let key = try await library.changePassphrase(current: current, to: new)
                Haptics.success()
                return key
            }
        }
    }

    /// A small form whose action may return a recovery key to show next.
    private func form<Fields: View>(title: String, note: String, ready: Bool, @ViewBuilder fields: () -> Fields,
                                    action: @escaping () async throws -> RecoveryKey?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(note).font(.subheadline).foregroundStyle(.secondary)
                fields()
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryCapsuleButton(title: "Continue", enabled: ready && !busy, busy: busy) {
                busy = true
                error = nil
                Task {
                    defer { busy = false }
                    do {
                        if let key = try await action() { sheet = .show(key) } else { sheet = nil }
                        needsUpgrade = library.needsHeaderUpgrade
                    } catch {
                        Haptics.error()
                        self.error = error.localizedDescription
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(title)
        .inlineNavigationTitle()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { sheet = nil }.disabled(busy) } }
    }
}

/// A recovery key as a sheet item.
struct IdentifiedKey: Identifiable {
    let key: RecoveryKey
    var id: String { key.text }
}
