import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit

/// BGProcessingTask for overnight catch-up, BGAppRefreshTask for index sync, and (iOS 26+)
/// BGContinuedProcessingTask so a user-started backup keeps running with system progress UI.
enum BackgroundTasks {
    static let processingId = "com.shahil-kv.memvo.backup.processing"
    static let refreshId = "com.shahil-kv.memvo.index.refresh"
    static let continuedId = "com.shahil-kv.memvo.backup.continued"

    /// Must run before the app finishes launching.
    static func register() {
        let scheduler = BGTaskScheduler.shared
        scheduler.register(forTaskWithIdentifier: processingId, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handleProcessing(task)
        }
        scheduler.register(forTaskWithIdentifier: refreshId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handleRefresh(task)
        }
    }

    /// Continued-processing tasks are registered just before their first submission (per Apple's guidance).
    @MainActor private static var continuedRegistered = false

    #if !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    @MainActor static func registerContinuedIfNeeded() {
        guard !continuedRegistered else { return }
        continuedRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedId, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            ContinuedBackup.handle(task)
        }
    }
    #endif

    static func scheduleAll() {
        scheduleProcessing()
        scheduleRefresh()
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingId)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch { AppLog.shared.warn("Scheduling processing task failed: \(error)") }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshId)
        request.earliestBeginDate = Date().addingTimeInterval(4 * 60 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch { AppLog.shared.warn("Scheduling refresh task failed: \(error)") }
    }

    private static func handleProcessing(_ task: BGProcessingTask) {
        scheduleProcessing()
        let flag = CancelFlag()
        task.expirationHandler = { flag.cancel() }
        Task {
            let summary = await AppEnvironment.shared.engine.run(isCancelled: { flag.isCancelled })
            appLog("Overnight backup: \(summary.text)")
            task.setTaskCompleted(success: summary.error == nil)
        }
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task {
            let env = AppEnvironment.shared
            if env.isConfigured, (try? await env.td.waitUntilReady(timeout: 20)) != nil {
                _ = try? await env.library.scan(full: false)
            }
            await env.enforceCacheLimits()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}

#else

/// macOS has no BGTaskScheduler: while Memvo is open, a system-scheduled activity checks for new
/// photos and refreshes the index every hour (it respects Wi-Fi only / charging only through the engine).
enum BackgroundTasks {
    private static let scheduler: NSBackgroundActivityScheduler = {
        let s = NSBackgroundActivityScheduler(identifier: "com.shahil-kv.memvo.mac.hourly")
        s.repeats = true
        s.interval = 60 * 60
        s.tolerance = 10 * 60
        s.qualityOfService = .utility
        return s
    }()
    private nonisolated(unsafe) static var scheduled = false

    static func register() {}

    static func scheduleAll() {
        guard !scheduled else { return }
        scheduled = true
        scheduler.schedule { completion in
            Task {
                let env = AppEnvironment.shared
                if env.isConfigured, (try? await env.td.waitUntilReady(timeout: 20)) != nil {
                    _ = try? await env.library.scan(full: false)
                    if Prefs.autoBackup && !Prefs.backupPaused {
                        let summary = await env.engine.run(isCancelled: { scheduler.shouldDefer })
                        appLog("Hourly backup: \(summary.text)")
                    }
                }
                await env.enforceCacheLimits()
                completion(.finished)
            }
        }
    }
}
#endif

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// User-started "Back up now". On iOS 26+ it runs as a continued-processing task with progress in the
/// system UI; earlier versions run while the app is open (uploads still finish in the background).
enum ContinuedBackup {
    @MainActor static var foregroundTask: Task<Void, Never>?
    /// Whether the run started by `start` also queues every photo not yet in the cloud.
    private nonisolated(unsafe) static var includeNew = false

    /// `everything`: "Back up now" (all photos not in the cloud). Otherwise only already-queued items
    /// (photos chosen with Back up, retries) are uploaded.
    @MainActor
    static func start(everything: Bool = false) {
        includeNew = everything
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            BackgroundTasks.registerContinuedIfNeeded()
            let request = BGContinuedProcessingTaskRequest(identifier: BackgroundTasks.continuedId,
                                                           title: "Backing up to Telegram",
                                                           subtitle: "Preparing…")
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                appLog("Submitted continued-processing backup")
                return
            } catch {
                AppLog.shared.warn("Continued processing unavailable (\(error.localizedDescription)); running in app")
            }
        }
        #endif
        runInForeground()
    }

    @MainActor
    static func runInForeground() {
        guard foregroundTask == nil else { return }
        foregroundTask = Task {
            let flag = CancelFlag()
            #if os(iOS)
            let bg = UIApplication.shared.beginBackgroundTask(withName: "Backup") { flag.cancel() }
            _ = await AppEnvironment.shared.engine.run(userStarted: true, includeNew: includeNew, isCancelled: { flag.isCancelled })
            UIApplication.shared.endBackgroundTask(bg)
            #else
            // Keeps App Nap and idle sleep from throttling a long upload while the window is in the background.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "Backing up to Telegram")
            _ = await AppEnvironment.shared.engine.run(userStarted: true, includeNew: includeNew, isCancelled: { flag.isCancelled })
            ProcessInfo.processInfo.endActivity(activity)
            #endif
            foregroundTask = nil
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    static func handle(_ task: BGContinuedProcessingTask) {
        let flag = CancelFlag()
        let started = Date()
        task.expirationHandler = {
            flag.cancel()
            appLog(String(format: "iOS ended the continued-processing backup after %.0f s", Date().timeIntervalSince(started)))
        }
        task.progress.totalUnitCount = 1
        // iOS ends a continued-processing task whose progress stops moving. Counting only finished items left it still
        // for the whole upload of a big video, and iOS stopped the backup after a few items; report the bytes of the
        // uploads in flight every second instead.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                let a = BackupActivity.shared
                let inFlight = a.lanes.values.reduce(0.0) { $0 + ($1.total > 0 ? Double($1.sent) / Double($1.total) : 0) }
                task.progress.totalUnitCount = Int64(max(a.total, 1)) * 100
                task.progress.completedUnitCount = min(task.progress.totalUnitCount - 1, Int64(a.done) * 100 + Int64(inFlight * 100))
                if a.total > 0 { task.updateTitle("Backing up to Telegram", subtitle: "\(a.done) of \(a.total) items") }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        Task {
            let summary = await AppEnvironment.shared.engine.run(userStarted: true, includeNew: includeNew, isCancelled: { flag.isCancelled })
            ticker.cancel()
            task.updateTitle("Backup finished", subtitle: summary.text)
            task.setTaskCompleted(success: !flag.isCancelled && summary.error == nil)
            // Ended by iOS while the user is in the app: carry on in the app rather than stopping half-way.
            if flag.isCancelled, summary.remaining > 0 {
                await MainActor.run {
                    guard UIApplication.shared.applicationState == .active else { return }
                    appLog("Continuing the backup in the app (\(summary.remaining) items left)")
                    runInForeground()
                }
            }
        }
    }
    #endif
}
