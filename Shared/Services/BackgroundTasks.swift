import Foundation
import LelvoCore
#if os(iOS)
import BackgroundTasks
import UIKit

/// BGProcessingTask for overnight catch-up, BGAppRefreshTask for index sync, and (iOS 26+)
/// BGContinuedProcessingTask so a user-started backup keeps running with system progress UI.
enum BackgroundTasks {
    static let processingId = "app.lelvo.ios.backup.processing"
    static let refreshId = "app.lelvo.ios.index.refresh"
    static let continuedId = "app.lelvo.ios.backup.continued"

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
        // Counting reads SQLite, so it stays off the main thread (this is called when the app goes to the background).
        Task.detached(priority: .utility) {
            let counts = (try? AppEnvironment.shared.store.counts()) ?? [:]
            let waiting = (counts[.queued] ?? 0) + (counts[.uploading] ?? 0) > 0
            let request = BGProcessingTaskRequest(identifier: processingId)
            request.requiresExternalPower = Prefs.chargingOnly
            request.requiresNetworkConnectivity = true
            // As soon as iOS likes while photos wait, otherwise once an hour.
            request.earliestBeginDate = waiting ? nil : Date().addingTimeInterval(60 * 60)
            do { try BGTaskScheduler.shared.submit(request) } catch { AppLog.shared.warn("Scheduling processing task failed: \(error)") }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshId)
        // iOS decides when it really runs; asking often costs nothing and it favours apps people open.
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch { AppLog.shared.warn("Scheduling refresh task failed: \(error)") }
    }

    private static func handleProcessing(_ task: BGProcessingTask) {
        let flag = CancelFlag()
        task.expirationHandler = { flag.cancel() }
        Task {
            let summary = await processingWork(isCancelled: { flag.isCancelled })
            // After the run, so the schedule knows whether photos are still waiting.
            scheduleProcessing()
            task.setTaskCompleted(success: summary.error == nil)
        }
    }

    /// The long overnight run. Also used by the Background lab (Debug).
    @discardableResult
    static func processingWork(isCancelled: @escaping @Sendable () -> Bool) async -> BackupEngine.Summary {
        let started = Date()
        let summary = await AppEnvironment.shared.engine.run(isCancelled: isCancelled)
        recordRun(.processing, started: started, summary: summary)
        // Reading photos for search is only worth the battery on the charger.
        if Device.isCharging { await AppEnvironment.shared.search.index(isCancelled: isCancelled) }
        return summary
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let flag = CancelFlag()
        task.expirationHandler = { flag.cancel() }
        Task {
            // iOS gives a refresh task about 30 s: stop uploading at 22 s so the bookkeeping finishes first.
            await refreshWork(deadline: Date().addingTimeInterval(22), isCancelled: { flag.isCancelled })
            task.setTaskCompleted(success: true)
        }
    }

    /// The short background run: photos and small videos. Also used by the Background lab (Debug).
    static func refreshWork(deadline: Date, isCancelled: @escaping @Sendable () -> Bool) async {
        let env = AppEnvironment.shared
        guard env.isConfigured, (try? await env.td.waitUntilReady(timeout: 10)) != nil else { return }
        if Prefs.autoBackup, !Prefs.backupPaused {
            let started = Date()
            // The engine scans the channel itself before it uploads.
            let summary = await env.engine.run(deadline: deadline, shortRun: true, isCancelled: isCancelled)
            recordRun(.refresh, started: started, summary: summary)
        } else {
            _ = try? await env.library.scan(full: false)
        }
        await env.enforceCacheLimits()
    }
}

#else

/// macOS has no BGTaskScheduler: while Lelvo is open, a system-scheduled activity checks for new
/// photos and refreshes the index every hour (it respects Wi-Fi only / charging only through the engine).
enum BackgroundTasks {
    private static let scheduler: NSBackgroundActivityScheduler = {
        let s = NSBackgroundActivityScheduler(identifier: "app.lelvo.mac.hourly")
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

/// Remembers a finished run (counts only) and writes one log line for it.
func recordRun(_ source: RunSource, started: Date, summary: BackupEngine.Summary) {
    let seconds = Date().timeIntervalSince(started)
    Prefs.record(RunRecord(source: source, startedAt: started, seconds: seconds,
                           uploaded: summary.uploaded, remaining: summary.remaining))
    appLog(String(format: "Run (%@): %.0f s, uploaded %d, %d waiting", source.rawValue, seconds, summary.uploaded, summary.remaining))
}

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
/// Thread-safe "Lelvo is on screen", kept up to date from the app's lifecycle notifications.
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

#if os(iOS)
/// Starts a backup when Lelvo opens and there is something to send. Each start shows an iOS progress indicator, so it
/// stays quiet when nothing is new and doesn't repeat for short visits.
enum AutoStart {
    @MainActor private static var lastStart = Date.distantPast

    @MainActor static func onOpen() {
        let activity = BackupActivity.shared
        let env = AppEnvironment.shared
        guard env.isConfigured, !activity.isRunning, !activity.isStarting, !env.engine.isRunning,
              ContinuedBackup.foregroundTask == nil,
              Date().timeIntervalSince(lastStart) > 5 * 60,
              env.engine.blocker() == nil else { return }
        lastStart = Date()
        Task.detached(priority: .utility) {
            let fresh = env.engine.enqueueNewAssets(force: false)
            let counts = (try? env.store.counts()) ?? [:]
            let waiting = (counts[.queued] ?? 0) + (counts[.uploading] ?? 0)
            guard waiting > 0 else { appLog("Auto-start on open: nothing new"); return }
            appLog("Auto-start on open: \(fresh) new photos, \(waiting) waiting")
            await MainActor.run { ContinuedBackup.start(everything: true) }
        }
    }
}
#endif

enum ContinuedBackup {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Whether Lelvo is on screen, readable from iOS's background callbacks (which don't run on the main thread).
    private static let appActive = ActiveFlag()
    #endif
    @MainActor static var foregroundTask: Task<Void, Never>?
    /// A user-started backup that iOS ended before it finished; resumed when Lelvo is next on screen.
    @MainActor private static var resumePending = false
    /// iOS started the task asked for by the last `start`.
    @MainActor private static var continuedTaskBegan = false

    /// Called when Lelvo comes to the front (and after iOS ends a backup): starts the unfinished one again.
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
        // Already on its way. A second request is what used to make the second tap "work": iOS refused it, and the fallback
        // ran the backup in the app.
        let activity = BackupActivity.shared
        guard !activity.isRunning, !activity.isStarting else { return }
        activity.isStarting = true
        Task { @MainActor in
            // Every path clears this; never leave the button stuck if one doesn't.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            activity.isStarting = false
        }
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
                continuedTaskBegan = false
                // iOS can accept the request and never run it, which left "Back up now" doing nothing.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !continuedTaskBegan, foregroundTask == nil, !AppEnvironment.shared.engine.isRunning else { return }
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTasks.continuedId)
                    AppLog.shared.warn("iOS didn't start the continued-processing backup; running in app")
                    runInForeground()
                }
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
            let started = Date()
            let summary = await AppEnvironment.shared.engine.run(userStarted: true, includeNew: includeNew, isCancelled: { flag.isCancelled })
            recordRun(.app, started: started, summary: summary)
            UIApplication.shared.endBackgroundTask(bg)
            #else
            // Keeps App Nap and idle sleep from throttling a long upload while the window is in the background.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "Backing up to Telegram")
            let started = Date()
            let summary = await AppEnvironment.shared.engine.run(userStarted: true, includeNew: includeNew, isCancelled: { flag.isCancelled })
            recordRun(.app, started: started, summary: summary)
            ProcessInfo.processInfo.endActivity(activity)
            #endif
            foregroundTask = nil
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    static func handle(_ task: BGContinuedProcessingTask) {
        Task { @MainActor in continuedTaskBegan = true }
        let flag = CancelFlag()
        let started = Date()
        let note = ProgressNote()
        task.expirationHandler = {
            let p = ProcessInfo.processInfo
            appLog(String(format: "iOS ended the continued-processing backup after %.0f s (app %@, thermal %d, low power %@; %@)",
                          Date().timeIntervalSince(started), appActive.value ? "on screen" : "in background",
                          p.thermalState.rawValue, p.isLowPowerModeEnabled ? "on" : "off", note.summary))
            flag.cancel()
            task.updateTitle("Backup paused", subtitle: "Open Lelvo to continue")
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
            recordRun(.continued, started: started, summary: summary)
            ticker.cancel()
            task.updateTitle(flag.isCancelled ? "Backup paused" : "Backup finished",
                             subtitle: flag.isCancelled ? "Open Lelvo to continue" : summary.text)
            // Paused by iOS isn't a failure (it resumes when Lelvo opens), and iOS shows "failed" for success: false.
            task.setTaskCompleted(success: summary.error == nil || flag.isCancelled)
            // Ended by iOS half-way: resume as a new system task (with its indicator) as soon as Lelvo is open, which
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
