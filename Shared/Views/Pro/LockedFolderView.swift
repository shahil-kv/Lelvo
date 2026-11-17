import SwiftUI

/// Gate for Locked folder: Pro paywall, Google Photos–style first-time setup, then Face ID / passcode, then content.
/// Membership syncs via MetaLog (#129). Photos are never deleted from Telegram — only hidden in Lelvo on every device.
struct LockedFolderGate<Content: View>: View {
    @ObservedObject private var locked = LockedFolderStore.shared
    @ObservedObject private var pro = ProStore.shared
    @State private var showPaywall = false
    @State private var authError: String?
    @State private var unlocking = false
    /// Avoid double Face ID prompts if the view reappears while a prompt is up (Apple Photos Hidden auto-prompt).
    @State private var didAutoPrompt = false
    @ViewBuilder var unlocked: () -> Content

    var body: some View {
        Group {
            if !pro.isPro {
                lockedOutPro
            } else if !locked.isSetUp {
                setupGate
            } else if !locked.unlockedThisSession {
                unlockGate
            } else {
                unlocked()
            }
        }
        .navigationTitle("Locked")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ProBadge() }
        }
        #endif
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
        // Google Photos: leaving Locked Folder re-locks so the next open needs Face ID again.
        .onDisappear {
            locked.lockSession()
            didAutoPrompt = false
        }
        .task(id: autoPromptKey) {
            // Apple Photos Hidden: open the folder → Face ID comes up on its own.
            guard pro.isPro, locked.isSetUp, !locked.unlockedThisSession, !didAutoPrompt, BiometricGate.canEvaluate else { return }
            didAutoPrompt = true
            await unlock()
        }
        .task(id: pro.isPro) {
            // Second device: pull MetaLog lock notes so iPhone/Android membership shows here.
            guard pro.isPro else { return }
            await locked.syncFromChannel()
        }
    }

    private var autoPromptKey: String {
        "\(pro.isPro)-\(locked.isSetUp)-\(locked.unlockedThisSession)"
    }

    private var lockedOutPro: some View {
        ContentUnavailableView {
            Label("Locked folder", systemImage: "lock.fill")
        } description: {
            Text("Hide photos behind \(BiometricGate.biometryTitle). Included with Lelvo Pro.")
        } actions: {
            Button("See Lelvo Pro") { showPaywall = true }
                .buttonStyle(.borderedProminent)
        }
    }

    /// First visit: authenticate once to create the folder (Google Photos "Set up Locked Folder").
    private var setupGate: some View {
        ContentUnavailableView {
            Label("Locked folder", systemImage: "lock.fill")
        } description: {
            Text("Photos you move here stay hidden in Lelvo on every device signed into this library. Unlock with \(BiometricGate.biometryTitle). Your Telegram library still holds the files.")
        } actions: {
            Button {
                Task { await setup() }
            } label: {
                if unlocking {
                    ProgressView()
                } else {
                    Text("Set up Locked Folder")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(unlocking || !BiometricGate.canEvaluate)
            if let authError {
                Text(authError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var unlockGate: some View {
        ContentUnavailableView {
            Label("Locked folder", systemImage: "lock.fill")
        } description: {
            Text(locked.count == 0
                 ? "Nothing here yet. Unlock to add photos, or select photos in your library and move them here."
                 : "Unlock with \(BiometricGate.biometryTitle) to see your hidden photos.")
        } actions: {
            Button {
                Task { await unlock() }
            } label: {
                if unlocking {
                    ProgressView()
                } else {
                    Text("Unlock with \(BiometricGate.biometryTitle)")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(unlocking || !BiometricGate.canEvaluate)
            if let authError {
                Text(authError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func setup() async {
        unlocking = true
        authError = nil
        defer { unlocking = false }
        do {
            try await BiometricGate.unlock(reason: "Set up Locked folder")
            locked.markSetUp()
            locked.markSessionUnlocked()
            Haptics.success()
        } catch BiometricGate.Failure.cancelled {
            // quiet — user can tap Set up again
        } catch {
            authError = (error as? LocalizedError)?.errorDescription ?? "Couldn't set up Locked folder. Try again."
            Haptics.error()
        }
    }

    private func unlock() async {
        guard !unlocking else { return }
        unlocking = true
        authError = nil
        defer { unlocking = false }
        do {
            try await BiometricGate.unlock()
            locked.markSessionUnlocked()
            Haptics.success()
        } catch BiometricGate.Failure.cancelled {
            // quiet — Unlock button remains
        } catch {
            authError = (error as? LocalizedError)?.errorDescription ?? "Couldn't unlock. Try again."
            Haptics.error()
        }
    }
}

#if os(iOS)
/// iPhone Locked folder: unlock, then the same grid as the rest of the app.
struct LockedFolderView: View {
    var body: some View {
        LockedFolderGate {
            GalleryView(filter: .locked, embedInNavigation: false)
        }
    }
}
#endif

/// Ente-style auto-lock grace for Locked folder (device auth still required to open and to move items in).
struct LockedFolderSettingsView: View {
    @AppStorage(Prefs.Key.lockedFolderAutoLockMs) private var autoLockMs = 5_000
    @ObservedObject private var locked = LockedFolderStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Auto-lock", selection: $autoLockMs) {
                    ForEach(LockedFolderStore.autoLockOptionsMs, id: \.self) { ms in
                        Text(Self.label(ms)).tag(ms)
                    }
                }
            } footer: {
                Text("After Lelvo has been in the background this long, Locked Folder needs \(BiometricGate.biometryTitle) again. The app switcher always blurs Locked Folder while it’s open, even before auto-lock.")
            }

            Section {
                LabeledContent("Unlock with", value: BiometricGate.biometryTitle)
            } footer: {
                Text("Locked membership syncs through your Telegram library as a small note (like favorites), so every Lelvo device agrees. Photo files are never moved or deleted. Sharing and deleting are blocked inside Locked Folder. Opening the channel in Telegram can still list files unless the library is end-to-end encrypted.")
            }
        }
        .navigationTitle("Locked Folder")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ProBadge() }
        }
        #endif
    }

    private static func label(_ ms: Int) -> String {
        switch ms {
        case 0: return "Immediately"
        case 5_000: return "After 5 seconds"
        case 15_000: return "After 15 seconds"
        case 60_000: return "After 1 minute"
        case 300_000: return "After 5 minutes"
        case 1_800_000: return "After 30 minutes"
        default: return "After \(ms / 1000) seconds"
        }
    }
}
