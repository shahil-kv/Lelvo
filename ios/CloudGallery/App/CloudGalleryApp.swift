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

    enum Tab: Hashable { case gallery, albums, backup, settings }

    @Published var onboardingComplete = Prefs.onboardingComplete
    @Published var selectedTab: Tab = .gallery
    @Published var showFreeUpSpace = false
    /// The Telegram session ended (logged out elsewhere, revoked): show sign-in again.
    @Published var needsSignIn = false
    private var authObserver: UUID?

    init() {
        authObserver = TDService.shared.observeAuth { _ in
            Task { @MainActor in
                // Re-read the current state: the startup "no client yet" state must not flash sign-in.
                let step = TDService.shared.auth
                let signedOut = step == .waitPhone || (step == .needsCredentials && TDCredentials.load() == nil)
                AppModel.shared.needsSignIn = signedOut && AppModel.shared.onboardingComplete
            }
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Prefs.Key.onboardingComplete)
        onboardingComplete = true
        needsSignIn = false
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

    init() {
        UITestSupport.prepareIfNeeded()
    }

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

/// Launch arguments used only by the UI smoke tests.
enum UITestSupport {
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-UITestDemoLibrary") }

    static func prepareIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UITestReset") {
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
            KeychainStore.wipe()
        }
        guard isDemo else { return }
        UserDefaults.standard.set(true, forKey: Prefs.Key.onboardingComplete)
        let store = AppEnvironment.shared.store
        let now = Date()
        let items = (0..<300).map { i -> MediaItem in
            var item = MediaItem(localIdentifier: nil, sha256: String(format: "%064d", i), filename: "IMG_\(1000 + i).HEIC",
                                 kind: i % 7 == 0 ? .video : .photo, creationDate: now.addingTimeInterval(Double(-i) * 9_000),
                                 fileSize: 2_000_000, status: .backedUp)
            item.setParts([RemoteFile(messageId: Int64(i + 1), fileId: "demo", fileUniqueId: "demo\(i)", size: 2_000_000)],
                          role: "o", expected: 1)
            return item
        }
        try? store.upsert(items)
    }
}
