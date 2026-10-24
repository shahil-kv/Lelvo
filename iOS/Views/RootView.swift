import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
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
                .fullScreenCover(isPresented: $model.needsSignIn) {
                    OnboardingView().environmentObject(model)
                }
            } else {
                OnboardingView()
            }
        }
        .animation(.default, value: model.onboardingComplete)
    }
}
