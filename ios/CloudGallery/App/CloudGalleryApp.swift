import SwiftUI
import UIKit
import CloudGalleryCore

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let env = AppEnvironment.shared
        BackgroundTasks.register()
        env.td.start()
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppEnvironment.shared.media.trimMemory()
    }
}

/// UI-wide state: onboarding status and deep-link navigation (e.g. from the Free Up Space shortcut).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Tab: Hashable { case gallery, backup, settings }

    @Published var onboardingComplete = Prefs.onboardingComplete
    @Published var selectedTab: Tab = .gallery
    @Published var showFreeUpSpace = false

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Prefs.Key.onboardingComplete)
        onboardingComplete = true
        BackgroundTasks.scheduleAll()
    }

    func openFreeUpSpace() {
        selectedTab = .backup
        showFreeUpSpace = true
    }

    func reset() async {
        await AppEnvironment.shared.resetEverything()
        onboardingComplete = false
        selectedTab = .gallery
    }
}

@main
struct CloudGalleryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(BackupActivity.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            let env = AppEnvironment.shared
            switch phase {
            case .active:
                guard model.onboardingComplete else { return }
                env.td.start()
                Task { await env.enforceCacheLimits() }
            case .background:
                env.originalsCache.flush()
                env.thumbnailCache.flush()
                if model.onboardingComplete { BackgroundTasks.scheduleAll() }
            default: break
            }
        }
    }
}
