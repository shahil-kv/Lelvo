import SwiftUI

/// Gate for Locked folder: Pro paywall, then Face ID / passcode, then the unlocked content.
/// Membership is local to this device for now. Photos are never deleted — only hidden from the main timeline.
struct LockedFolderGate<Content: View>: View {
    @ObservedObject private var locked = LockedFolderStore.shared
    @ObservedObject private var pro = ProStore.shared
    @State private var showPaywall = false
    @State private var authError: String?
    @State private var unlocking = false
    @ViewBuilder var unlocked: () -> Content

    var body: some View {
        Group {
            if !pro.isPro {
                lockedOutPro
            } else if !locked.unlockedThisSession {
                gate
            } else {
                unlocked()
            }
        }
        .navigationTitle("Locked")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
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

    private var gate: some View {
        ContentUnavailableView {
            Label("Locked folder", systemImage: "lock.fill")
        } description: {
            Text(locked.ids.isEmpty
                 ? "Nothing here yet. Select photos in your library and move them to Locked folder."
                 : "\(locked.count.formatted()) hidden. Unlock with \(BiometricGate.biometryTitle) to see them.")
        } actions: {
            if !locked.ids.isEmpty {
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
            }
            if let authError {
                Text(authError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func unlock() async {
        unlocking = true
        authError = nil
        defer { unlocking = false }
        do {
            try await BiometricGate.unlock()
            locked.markSessionUnlocked()
            Haptics.success()
        } catch BiometricGate.Failure.cancelled {
            // quiet
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
