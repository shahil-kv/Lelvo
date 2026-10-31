import SwiftUI
import LelvoCore

/// UI-wide state: onboarding status and deep-link navigation (e.g. from the Free Up Space shortcut).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Tab: Hashable { case gallery, collections, search, backup }

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
                // Every step of signing in counts, not only the phone number: after the number, Telegram waits for the
                // code (and maybe the 2-step password), and treating that as signed in hid the sign-in screen.
                let signedOut: Bool
                switch step {
                case .waitPhone, .waitCode, .waitPassword, .waitEmail, .waitOtherDevice, .waitRegistration: signedOut = true
                case .needsCredentials: signedOut = TDCredentials.load() == nil
                case .starting, .ready, .loggingOut, .closed: signedOut = false
                }
                AppModel.shared.needsSignIn = signedOut && AppModel.shared.onboardingComplete && !UITestSupport.isDemo && !DemoMode.isActive
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

    /// Bumped by `reset()` so the signed-in screens are rebuilt with nothing of the old account in memory.
    @Published private(set) var sessionId = UUID()
    /// The wipe `reset()` started. It can still be running while the welcome screen is up.
    private var resetTask: Task<Void, Never>?

    /// Shows the welcome screen at once, then wipes in the background. Waiting for the wipe first left Settings on
    /// screen for seconds, because signing out waits for Telegram to answer.
    func reset() {
        onboardingComplete = false
        needsSignIn = false
        showFreeUpSpace = false
        selectedTab = .gallery
        sessionId = UUID()
        let previous = resetTask
        resetTask = Task {
            await previous?.value
            await AppEnvironment.shared.resetEverything()
        }
    }

    /// Returns once a running reset has finished. Sign-in waits for this so it never sees the old session.
    func waitForReset() async {
        await resetTask?.value
    }
}

/// Launch arguments used only by the UI tests and benchmarks. Release builds ignore them, so nothing outside a
/// debug build can wipe the settings or replace the library with demo items.
enum UITestSupport {
    #if DEBUG
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-UITestDemoLibrary") }
    #else
    static let isDemo = false
    #endif

    /// `-TestUploadLimitMiB <n>`: splits uploads above n MiB, so resuming a split upload can be tried with a small video
    /// instead of one over 2 GB.
    static var uploadLimitOverride: Int64? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-TestUploadLimitMiB"), i + 1 < args.count, let mib = Int64(args[i + 1]), mib > 1 else { return nil }
        return mib * PartLayout.mib
        #else
        return nil
        #endif
    }

    static func prepareIfNeeded() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UITestReset") {
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
            KeychainStore.wipe()
        }
        guard isDemo else { return }
        UserDefaults.standard.set(true, forKey: Prefs.Key.onboardingComplete)
        let store = AppEnvironment.shared.store
        // `-UITestDemoFromPhotos` (website screenshots): the photos already on the device become the backed-up library,
        // except every ninth one, which stays "not backed up" so that state shows too.
        if args.contains("-UITestDemoFromPhotos"), PhotoLibraryService.hasAccess {
            var items: [MediaItem] = []
            var index = 0
            AppEnvironment.shared.photos.fetchAllAssets().enumerateObjects { asset, _, _ in
                defer { index += 1 }
                guard index % 9 != 8 else { return }
                var item = MediaItem(localIdentifier: asset.localIdentifier, sha256: String(format: "%064d", index),
                                     filename: "IMG_\(4000 + index).HEIC", kind: PhotoLibraryService.kind(of: asset),
                                     creationDate: asset.creationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                     duration: asset.mediaType == .video ? asset.duration : nil, fileSize: 3_400_000, status: .backedUp)
                item.uploadedAt = asset.creationDate
                item.setParts([RemoteFile(messageId: Int64(index + 1), fileId: "demo", fileUniqueId: "demo\(index)", size: 3_400_000)],
                              role: "o", expected: 1)
                items.append(item)
            }
            try? store.deleteAll()
            try? store.upsert(items)
            return
        }
        let now = Date()
        // `-UITestDemoCount N` (benchmarks): a bigger library; default 300 for the UI tests.
        let count = args.firstIndex(of: "-UITestDemoCount").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 300
        let items = (0..<count).map { i -> MediaItem in
            var item = MediaItem(localIdentifier: nil, sha256: String(format: "%064d", i), filename: "IMG_\(1000 + i).HEIC",
                                 kind: i % 7 == 0 ? .video : .photo, creationDate: now.addingTimeInterval(Double(-i) * 9_000),
                                 fileSize: 2_000_000, status: .backedUp)
            if i % 7 == 0 { item.duration = Double(5 + i % 90) }
            // Places for the map, Memories and Search: most around home, and a four-day trip.
            let trip = (200..<240).contains(i)
            let jitter = Double(i % 13) * 0.002
            item.latitude = (trip ? 15.49 : 9.93) + jitter
            item.longitude = (trip ? 73.82 : 76.26) + jitter
            item.setParts([RemoteFile(messageId: Int64(i + 1), fileId: "demo", fileUniqueId: "demo\(i)", size: 2_000_000)],
                          role: "o", expected: 1)
            return item
        }
        try? store.deleteAll()
        try? store.upsert(items)
        ThumbnailPipeline.shared.seedDemoThumbnails(ids: items.map { "cloud-\($0.id)" })
        #endif
    }
}

