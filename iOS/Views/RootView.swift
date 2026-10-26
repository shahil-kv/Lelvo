import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var activity: BackupActivity
    @AppStorage(Prefs.Key.keepAwakeDuringBackup) private var keepAwake = true
    @StateObject private var gallery = GalleryModel()

    var body: some View {
        Group {
            if model.onboardingComplete {
                TabView(selection: $model.selectedTab) {
                    GalleryView()
                        .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                        .tag(AppModel.Tab.gallery)
                    AlbumsView()
                        .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                        .tag(AppModel.Tab.albums)
                    BackupDashboardView()
                        .tabItem { Label("Backup", systemImage: "icloud.and.arrow.up") }
                        .tag(AppModel.Tab.backup)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppModel.Tab.settings)
                }
                .environmentObject(gallery)
                .safeAreaInset(edge: .top, spacing: 0) { if DemoMode.isActive { DemoBanner() } }
                .fullScreenCover(isPresented: $model.needsSignIn) {
                    OnboardingView().environmentObject(model)
                }
            } else {
                OnboardingView()
            }
        }
        .animation(.default, value: model.onboardingComplete)
        // While a backup runs with Memvo open, the iPhone doesn't auto-lock: on iOS 26, a locked phone that goes to
        // sleep stops background tasks (an iOS bug Apple has acknowledged), which paused long backups.
        .onChange(of: activity.isRunning, initial: true) { _, running in UIApplication.shared.isIdleTimerDisabled = running && keepAwake }
        .onChange(of: keepAwake) { _, on in UIApplication.shared.isIdleTimerDisabled = on && activity.isRunning }
    }
}

/// Always visible in the App Review demo, so the sample library is never mistaken for a real one.
private struct DemoBanner: View {
    var body: some View {
        Label("Demo library: sample photos, nothing is uploaded", systemImage: "info.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))
            .accessibilityIdentifier("demoBanner")
    }
}
