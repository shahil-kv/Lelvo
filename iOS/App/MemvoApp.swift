import SwiftUI
import UIKit
import MemvoCore

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
        ThumbnailPipeline.shared.clearMemory()
    }
}

@main
struct MemvoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UITestSupport.prepareIfNeeded()
        #if DEBUG
        ScrollBenchmark.runIfRequested()
        #endif
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
                Task.detached(priority: .utility) { await GalleryActions.emptyExpiredTrash() }
                Task.detached(priority: .utility) {
                    guard env.library.needsRepairScan, (try? await env.td.waitUntilReady(timeout: 30)) != nil else { return }
                    _ = try? await env.library.scan(full: true)
                }
                #if DEBUG
                CloudReadCheck.runIfRequested()
                if ProcessInfo.processInfo.arguments.contains("-clearCacheTest") {
                    Task.detached {
                        try? await env.td.waitUntilReady(timeout: 30)
                        let before = env.media.cacheUsage
                        appLog("Clear test: before \(Format.bytes(before.total)) (thumbnails \(Format.bytes(before.thumbnails)), viewed \(Format.bytes(before.originals)), Telegram \(Format.bytes(before.telegram)))")
                        await env.media.clearCaches()
                    }
                }
                #endif
                // Cheap no-op unless restored items are still unlinked (e.g. right after a reinstall).
                Task.detached(priority: .userInitiated) { env.engine.relinkRestoredItems() }
            case .background:
                env.originalsCache.flush()
                env.thumbnailCache.flush()
                if model.onboardingComplete { BackgroundTasks.scheduleAll() }
            default: break
            }
        }
    }
}

#if DEBUG
/// Diagnostic (launch argument `-verifyCloudReads`): reads the first and last 64 KB of every backed-up
/// video through the player's code path and logs which ones can't be read.
enum CloudReadCheck {
    private static var started = false

    @MainActor static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-verifyCloudReads") || args.contains("-verifyCloudReadsName"), !started else { return }
        started = true
        Task.detached(priority: .utility) {
            let env = AppEnvironment.shared
            try? await env.td.waitUntilReady(timeout: 60)
            // Optional `-verifyCloudReadsName <filename>` limits the check to one file.
            let args = ProcessInfo.processInfo.arguments
            let only = args.firstIndex(of: "-verifyCloudReadsName").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            let videos = ((try? env.store.items(status: .backedUp)) ?? [])
                .filter { $0.kind == .video && $0.isViewableFromCloud && (only == nil || $0.filename == only) }
            appLog("Cloud read check: \(videos.count) videos")
            var failed = 0
            for item in videos {
                do {
                    let size = try await env.reader.plaintextSize(item, role: "o")
                    let head = try await env.reader.read(item, role: "o", range: 0..<min(size, 65536), streaming: true)
                    let tail = try await env.reader.read(item, role: "o", range: max(0, size - 65536)..<size, streaming: true)
                    if head.isEmpty || tail.isEmpty { throw MediaReader.ReadError.missing }
                    if args.contains("-verifyCloudReadsFull") {
                        // Sequential 1 MB reads like the player, timing the slow ones.
                        let started = Date()
                        var offset: Int64 = 0
                        while offset < size {
                            let t = Date()
                            let chunk = try await env.reader.read(item, role: "o", range: offset..<min(size, offset + (1 << 20)), streaming: true)
                            if chunk.isEmpty { throw MediaReader.ReadError.missing }
                            let dt = Date().timeIntervalSince(t)
                            if dt > 1 { appLog(String(format: "Cloud read check: %@ slice at %lld took %.1f s", item.filename, offset, dt)) }
                            offset += Int64(chunk.count)
                        }
                        let total = Date().timeIntervalSince(started)
                        appLog(String(format: "Cloud read check: %@ read fully in %.1f s (%.1f MB/s)", item.filename, total, Double(size) / 1_048_576 / max(total, 0.01)))
                    }
                } catch {
                    failed += 1
                    AppLog.shared.error("Cloud read check: \(item.filename) failed: \(error.localizedDescription)")
                }
            }
            appLog("Cloud read check finished: \(videos.count - failed) OK, \(failed) failed")
        }
    }
}
#endif
