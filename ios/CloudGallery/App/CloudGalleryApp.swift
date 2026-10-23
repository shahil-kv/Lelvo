import SwiftUI
import UIKit
import CloudGalleryCore

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let env = AppEnvironment.shared
        BackgroundTasks.register()
        env.uploader.activate()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        AppEnvironment.shared.uploader.attach(identifier: identifier, completion: completionHandler)
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

    func reset() {
        AppEnvironment.shared.resetEverything()
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
                Task { await env.engine.syncIndexIfIdle() }
            case .background:
                env.originalsCache.flush()
                env.thumbnailCache.flush()
                if model.onboardingComplete { BackgroundTasks.scheduleAll() }
            default: break
            }
        }
    }
}
