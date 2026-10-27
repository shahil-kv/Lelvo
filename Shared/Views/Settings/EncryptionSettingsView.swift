import SwiftUI
import MemvoCore

/// Shows a new recovery key once. Nothing in Memvo or Telegram keeps a readable copy, so the user has to save it now.
struct RecoveryKeyView: View {
    let key: RecoveryKey
    let onDone: () -> Void
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Save your recovery key", systemImage: "key.horizontal.fill").font(.title2.weight(.bold))
                Text("If you forget your passphrase, this key opens your library. Keep it somewhere safe, like a password manager or on paper. Anyone who has it and your Telegram account can open your photos.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(key.text)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Recovery key")
                    .accessibilityValue(key.text.replacingOccurrences(of: "-", with: " "))
                Button {
                    PlatformActions.copy(key.text)
                    copied = true
                    Haptics.success()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Toggle("I've saved my recovery key", isOn: $saved)
                Text("Memvo won't show this key again. You can make a new one in Settings with your passphrase.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryCapsuleButton(title: "Done", enabled: saved) { onDone() }.padding(20)
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
            let problem = EncryptionChoice.problem(encrypted: true, passphrase: new, confirm: confirm, acknowledged: true)
            form(title: "Change Passphrase",
                 note: needsUpgrade ? "Your library also gets a recovery key." : "Your recovery key keeps working.",
                 ready: !current.isEmpty && problem == nil) {
                OnboardingField(placeholder: "Current passphrase", text: $current, secure: true, content: .password, autofocus: true)
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
