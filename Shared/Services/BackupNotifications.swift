import Foundation
import LelvoCore
#if os(iOS)
import UserNotifications

/// Local notifications only, with counts and nothing else: a morning summary of what backed up overnight, and a
/// gentle reminder when photos have been waiting for days. Nothing is asked until the person turns this on.
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

    private static var nightTotals: NightTotals {
        get {
            guard let d = Prefs.defaults.data(forKey: Prefs.Key.nightTotals) else { return NightTotals() }
            return (try? JSONDecoder().decode(NightTotals.self, from: d)) ?? NightTotals()
        }
        set { Prefs.defaults.set(try? JSONEncoder().encode(newValue), forKey: Prefs.Key.nightTotals) }
    }

    /// Called after a background run (refresh or processing).
    static func afterRun(startedAt: Date, summary: BackupEngine.Summary) async {
        if summary.uploaded > 0 {
            Prefs.defaults.set(0, forKey: Prefs.Key.remindersSent)
            if BackgroundRuns.isOvernight(startedAt) {
                var t = nightTotals
                t.add(uploaded: summary.uploaded, videos: summary.uploadedVideos)
                nightTotals = t
            }
        }
        await flushSummary()
        await remindIfStuck(waiting: summary.remaining)
    }

    /// Posts the night's summary once it's morning, or when Lelvo opens.
    static func flushSummary() async {
        guard allowed, !BackgroundRuns.isOvernight(Date()), !nightTotals.isEmpty else { return }
        let t = nightTotals
        nightTotals = NightTotals()
        guard let text = BackgroundRuns.summaryText(photos: t.photos, videos: t.videos, overnight: true) else { return }
        await post(id: summaryId, title: "Backup finished", body: text, thread: "lelvo.backup.summary")
    }

    private static func remindIfStuck(waiting: Int) async {
        guard allowed else { return }
        let sent = Prefs.defaults.integer(forKey: Prefs.Key.remindersSent)
        let last = Prefs.defaults.object(forKey: Prefs.Key.lastBackupAt) as? Date
        guard let due = BackgroundRuns.nextReminder(lastUpload: last, waiting: waiting, remindersSent: sent, now: Date()),
              due <= Date() else { return }
        Prefs.defaults.set(sent + 1, forKey: Prefs.Key.remindersSent)
        await post(id: reminderId, title: "Backup waiting",
                   body: "\(waiting) \(waiting == 1 ? "item is" : "items are") waiting to be backed up. Open Lelvo to continue.",
                   thread: "lelvo.backup.reminder")
    }

    private static func post(id: String, title: String, body: String, thread: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        // A fixed identifier replaces the older one, so they never pile up.
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
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
