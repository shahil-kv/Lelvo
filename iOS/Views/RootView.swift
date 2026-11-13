import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var activity: BackupActivity
    @AppStorage(Prefs.Key.keepAwakeDuringBackup) private var keepAwake = true
    @StateObject private var gallery = GalleryModel()
    @StateObject private var memories = MemoriesModel()
    @AppStorage(Prefs.Key.communityNoteShown) private var communityNoteShown = false
    @State private var showingCommunityNote = false
    @State private var communityNoteHeight: CGFloat = 640

    var body: some View {
        Group {
            if model.onboardingComplete {
                TabView(selection: $model.selectedTab) {
                    GalleryView()
                        .noBottomEdgeEffect()
                        .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                        .tag(AppModel.Tab.gallery)
                    // Four tabs like Google Photos; Settings opens from the gear in Photos.
                    AlbumsView()
                        .noBottomEdgeEffect()
                        .tabItem { Label("Collections", systemImage: "rectangle.stack") }
                        .tag(AppModel.Tab.collections)
                    SearchView()
                        .noBottomEdgeEffect()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(AppModel.Tab.search)
                    BackupDashboardView()
                        .noBottomEdgeEffect()
                        .tabItem { Label("Backup", systemImage: "icloud.and.arrow.up") }
                        .tag(AppModel.Tab.backup)
                }
                .environmentObject(gallery)
                .environmentObject(memories)
                .task(id: gallery.revision) { if gallery.loaded { await memories.refresh(entries: gallery.entries, revision: gallery.revision) } }
                .modifier(DemoBannerAbove())
                .toastHost(bottomPadding: 64)
                .fullScreenCover(isPresented: $model.needsSignIn) {
                    OnboardingView().environmentObject(model)
                }
                // Once, a moment after the photos first show: someone who just signed in sees their library working
                // before being asked anything. Marked seen only when closed, so a killed app shows it again.
                .task(id: gallery.loaded) {
                    var forced = false
                    #if DEBUG
                    // `-ShowCommunityNote`: shows it now, also in the demo library, to check how it looks.
                    forced = ProcessInfo.processInfo.arguments.contains("-ShowCommunityNote")
                    #endif
                    // Not in UI tests either: the sheet would cover the screens they tap.
                    guard gallery.loaded, forced || (!communityNoteShown && !DemoMode.isActive && !UITestSupport.isRunning),
                          !model.needsSignIn else { return }
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled, !model.needsSignIn { showingCommunityNote = true }
                }
                .sheet(isPresented: $showingCommunityNote, onDismiss: { communityNoteShown = true }) {
                    CommunityNoteView(onClose: { showingCommunityNote = false }, onHeight: { communityNoteHeight = $0 + 24 })
                        .presentationDetents([.height(communityNoteHeight), .large])
                        // Solid: a part-height sheet is see-through glass on iOS 26, and the text over bright photos
                        // was hard to read.
                        .presentationBackground(Color(uiColor: .systemBackground))
                        .presentationDragIndicator(.visible)
                }
            } else {
                OnboardingView()
            }
        }
        .motion(Motion.standard, value: model.onboardingComplete)

        // While a backup runs with Lelvo open, the iPhone doesn't auto-lock: on iOS 26, a locked phone that goes to
        // sleep stops background tasks (an iOS bug Apple has acknowledged), which paused long backups.
        .onChange(of: activity.isRunning, initial: true) { _, running in UIApplication.shared.isIdleTimerDisabled = running && keepAwake }
        .onChange(of: keepAwake) { _, on in UIApplication.shared.isIdleTimerDisabled = on && activity.isRunning }
    }
}

private extension View {
    /// Every tab ends like Photos: no edge effect behind the floating tab bar. On iOS 26 and later it darkens what is
    /// there to a solid black strip (#100, #102); the glass bar keeps itself readable.
    @ViewBuilder func noBottomEdgeEffect() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectHidden(true, for: .bottom) } else { self }
    }
}

/// Stacks the banner above the tabs. A top safe area inset on a TabView doesn't move each tab's navigation bar down,
/// so the banner covered the toolbar buttons.
private struct DemoBannerAbove: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if DemoMode.isActive { DemoBanner() }
            content
        }
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
            .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea(edges: .top))
            .accessibilityIdentifier("demoBanner")
    }
}
