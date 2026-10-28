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
            // Then, still on the charger, read new photos for search.
            await AppEnvironment.shared.search.index(isCancelled: { flag.isCancelled })
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
                if Device.isCharging { await env.search.index(isCancelled: { scheduler.shouldDefer || !Device.isCharging }) }
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

/// What a continued-processing backup last reported, for the log line when iOS ends it: iOS ends these tasks when their
/// progress stands still, and some ended after only ~30 s.
final class ProgressNote: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = -1
    private var movedAt = Date()
    private var doing = "starting"

    func report(_ completed: Int64, doing now: String) {
        lock.withLock {
            if completed != value { value = completed; movedAt = Date() }
            doing = now
        }
    }

    var summary: String {
        lock.withLock { String(format: "progress last moved %.0f s before, %@", Date().timeIntervalSince(movedAt), doing) }
    }
}

/// User-started "Back up now". On iOS 26+ it runs as a continued-processing task with progress in the
/// system UI; earlier versions run while the app is open (uploads still finish in the background).
#if os(iOS) && !targetEnvironment(macCatalyst)
/// Thread-safe "Memvo is on screen", kept up to date from the app's lifecycle notifications.
final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var observing = false

    var value: Bool { lock.withLock { active } }

    @MainActor func observe() {
        guard !lock.withLock({ observing }) else { return }
        lock.withLock {
            observing = true
            active = UIApplication.shared.applicationState == .active
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.set(true) }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.set(false) }
    }

    private func set(_ v: Bool) { lock.withLock { active = v } }
}

#endif

enum ContinuedBackup {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Whether Memvo is on screen, readable from iOS's background callbacks (which don't run on the main thread).
    private static let appActive = ActiveFlag()
    #endif
    @MainActor static var foregroundTask: Task<Void, Never>?
    /// A user-started backup that iOS ended before it finished; resumed when Memvo is next on screen.
    @MainActor private static var resumePending = false

    /// Called when Memvo comes to the front (and after iOS ends a backup): starts the unfinished one again.
    @MainActor
    static func resumeIfPending() {
        #if os(iOS)
        guard resumePending, UIApplication.shared.applicationState == .active else { return }
        #else
        guard resumePending else { return }
        #endif
        resumePending = false
        appLog("Resuming the backup that iOS paused")
        start(everything: includeNew)
    }
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
            appActive.observe()
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
        let note = ProgressNote()
        task.expirationHandler = {
            let p = ProcessInfo.processInfo
            appLog(String(format: "iOS ended the continued-processing backup after %.0f s (app %@, thermal %d, low power %@; %@)",
                          Date().timeIntervalSince(started), appActive.value ? "on screen" : "in background",
                          p.thermalState.rawValue, p.isLowPowerModeEnabled ? "on" : "off", note.summary))
            flag.cancel()
            task.updateTitle("Backup paused", subtitle: "Open Memvo to continue")
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
                // A lane at 0 bytes is still exporting, hashing or encrypting its file; nothing is sent until that ends.
                let doing = a.lanes.isEmpty ? (a.message ?? "no upload running")
                    : a.lanes.values.map { $0.sent > 0 ? "uploading" : "preparing a file" }.sorted().joined(separator: " + ")
                note.report(task.progress.completedUnitCount, doing: doing)
                if a.total > 0 { task.updateTitle("Backing up to Telegram", subtitle: "\(a.done) of \(a.total) items") }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        Task {
            let summary = await AppEnvironment.shared.engine.run(userStarted: true, includeNew: includeNew, isCancelled: { flag.isCancelled })
            ticker.cancel()
            task.updateTitle(flag.isCancelled ? "Backup paused" : "Backup finished",
                             subtitle: flag.isCancelled ? "Open Memvo to continue" : summary.text)
            // Paused by iOS isn't a failure (it resumes when Memvo opens), and iOS shows "failed" for success: false.
            task.setTaskCompleted(success: summary.error == nil || flag.isCancelled)
            // Ended by iOS half-way: resume as a new system task (with its indicator) as soon as Memvo is open, which
            // iOS requires for starting one. Continuing inside the app had no indicator and stopped ~30 s after leaving.
            if flag.isCancelled, summary.remaining > 0 {
                await MainActor.run {
                    resumePending = true
                    resumeIfPending()
                }
            }
        }
    }
    #endif
}
