import SwiftUI

/// Ente "Hide content" / Immich #28999 fix: when Locked Folder is unlocked, blur the window in the app
/// switcher and Control Center so sensitive thumbnails never appear in the snapshot.
///
/// Auto-lock grace still applies on resume (Ente). This cover is independent of that grace — content is
/// hidden the moment the scene leaves `.active`, even for a 1-second peek.
struct LockedFolderPrivacyCover: ViewModifier {
    @ObservedObject private var locked = LockedFolderStore.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if locked.unlockedThisSession, scenePhase != .active {
                ZStack {
                    Rectangle().fill(.ultraThickMaterial)
                    VStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Locked Folder")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .animation(nil, value: scenePhase)
    }
}

extension View {
    /// Blur Locked Folder content in the app switcher while the unlock session is open.
    func lockedFolderPrivacyCover() -> some View {
        modifier(LockedFolderPrivacyCover())
    }
}
