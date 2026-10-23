import Foundation
import BackgroundTasks
import UIKit

/// BGProcessingTask for overnight catch-up, BGAppRefreshTask for index sync, and (iOS 26+)
/// BGContinuedProcessingTask so a user-started backup keeps running with system progress UI.
enum BackgroundTasks {
    static let processingId = "com.shahil-kv.cloudgallery.backup.processing"
    static let refreshId = "com.shahil-kv.cloudgallery.index.refresh"
    static let continuedId = "com.shahil-kv.cloudgallery.backup.continued"

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
        #if !targetEnvironment(macCatalyst)
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
            let bg = UIApplication.shared.beginBackgroundTask(withName: "Backup") { flag.cancel() }
            _ = await AppEnvironment.shared.engine.run(userStarted: true, includeNew: includeNew, isCancelled: { flag.isCancelled })
            UIApplication.shared.endBackgroundTask(bg)
            foregroundTask = nil
        }
    }

    #if !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    static func handle(_ task: BGContinuedProcessingTask) {
        let flag = CancelFlag()
        task.expirationHandler = { flag.cancel() }
        task.progress.totalUnitCount = 1
        Task {
            let summary = await AppEnvironment.shared.engine.run(userStarted: true, includeNew: includeNew, isCancelled: { flag.isCancelled }) { done, total in
                task.progress.totalUnitCount = Int64(max(total, 1))
                task.progress.completedUnitCount = Int64(done)
                task.updateTitle("Backing up to Telegram", subtitle: "\(done) of \(total) items")
            }
            task.updateTitle("Backup finished", subtitle: summary.text)
            task.setTaskCompleted(success: !flag.isCancelled && summary.error == nil)
        }
    }
    #endif
}
