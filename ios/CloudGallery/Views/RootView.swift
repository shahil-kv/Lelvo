import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.onboardingComplete {
                TabView(selection: $model.selectedTab) {
                    GalleryView()
                        .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                        .tag(AppModel.Tab.gallery)
                    BackupDashboardView()
                        .tabItem { Label("Backup", systemImage: "icloud.and.arrow.up") }
                        .tag(AppModel.Tab.backup)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppModel.Tab.settings)
                }
            } else {
                OnboardingView()
            }
        }
        .animation(.default, value: model.onboardingComplete)
    }
}
