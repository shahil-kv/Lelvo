import Foundation
import LelvoCore
#if os(iOS)
import UserNotifications

/// Local notifications only, with counts and nothing else: a morning summary of what backed up overnight, and a
/// gentle reminder when photos have been waiting for days. Nothing is asked until the person turns this on.
/// Both are booked ahead with a time trigger: when the backup is stuck, background runs are exactly what isn't
/// happening, so a reminder that waited for one would never come.
enum BackupNotifications {
    private static let summaryId = "lelvo.backup.summary"
    private static let reminderId = "lelvo.backup.reminder"

    static var allowed: Bool { Prefs.defaults.bool(forKey: Prefs.Key.notifyBackups) }

    /// Asks iOS the first time; returns whether notifications are now on.
    @discardableResult
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        Prefs.defaults.set(granted, forKey: Prefs.Key.notifyBackups)
        return granted
    }

    /// Stops both, when the person turns notifications off in Lelvo.
    static func disable() {
        Prefs.defaults.set(false, forKey: Prefs.Key.notifyBackups)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [summaryId, reminderId])
        Prefs.defaults.removeObject(forKey: Prefs.Key.reminderDueAt)
    }

    /// Called after a background run (refresh or processing).
    static func afterRun(startedAt: Date, summary: BackupEngine.Summary) async {
        if summary.uploaded > 0, BackgroundRuns.isOvernight(startedAt) {
            await addToNight(startedAt: startedAt, uploaded: summary.uploaded, videos: summary.uploadedVideos)
        }
        await bookReminder(waiting: summary.remaining)
    }

    /// Adds this run to its night and (re)books one notification for 07:30 with the night's total so far.
    private static func addToNight(startedAt: Date, uploaded: Int, videos: Int) async {
        let morning = BackgroundRuns.morning(after: startedAt)
        var totals = NightTotals()
        if Prefs.defaults.double(forKey: Prefs.Key.nightTotalsMorning) == morning.timeIntervalSince1970,
           let d = Prefs.defaults.data(forKey: Prefs.Key.nightTotals),
           let saved = try? JSONDecoder().decode(NightTotals.self, from: d) {
            totals = saved
        }
        totals.add(uploaded: uploaded, videos: videos)
        Prefs.defaults.set(try? JSONEncoder().encode(totals), forKey: Prefs.Key.nightTotals)
        Prefs.defaults.set(morning.timeIntervalSince1970, forKey: Prefs.Key.nightTotalsMorning)
        guard allowed, let text = BackgroundRuns.summaryText(photos: totals.photos, videos: totals.videos, overnight: true) else { return }
        await post(id: summaryId, title: "Backup finished", body: text, thread: summaryId, at: morning)
    }

    /// Books the stuck reminder from what is waiting now. Called when Lelvo goes to the background and after
    /// background runs; nothing waiting removes it.
    static func bookReminder(waiting: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderId])
        let now = Date()
        var sent = Prefs.defaults.integer(forKey: Prefs.Key.remindersSent)
        // A booked date that has passed means that reminder was shown: the next one waits longer.
        if let booked = Prefs.defaults.object(forKey: Prefs.Key.reminderDueAt) as? Date, booked <= now {
            sent += 1
            Prefs.defaults.set(sent, forKey: Prefs.Key.remindersSent)
            Prefs.defaults.removeObject(forKey: Prefs.Key.reminderDueAt)
        }
        let last = Prefs.defaults.object(forKey: Prefs.Key.lastBackupAt) as? Date
        guard allowed, let due = BackgroundRuns.nextReminder(lastUpload: last, waiting: waiting, remindersSent: sent, now: now) else {
            Prefs.defaults.removeObject(forKey: Prefs.Key.reminderDueAt)
            return
        }
        let at = BackgroundRuns.reminderFireDate(due: due, now: now)
        Prefs.defaults.set(at, forKey: Prefs.Key.reminderDueAt)
        await post(id: reminderId, title: "Backup waiting",
                   body: "\(waiting) \(waiting == 1 ? "item is" : "items are") waiting to be backed up. Open Lelvo to continue.",
                   thread: reminderId, at: at)
    }

    private static func post(id: String, title: String, body: String, thread: String, at date: Date) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        let seconds = max(date.timeIntervalSinceNow, 1)
        // A fixed identifier replaces the older one, so they never pile up.
        try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
    }
}

/// Tapping a notification opens the Backup tab.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppModel.shared.selectedTab = .backup }
    }
}
#endif
