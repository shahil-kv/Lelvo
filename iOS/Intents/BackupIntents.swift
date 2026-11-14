import AppIntents
import Foundation
import LelvoCore

/// Runs without opening the app: queues new photos as background uploads and reports what it did.
struct BackUpNewPhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up New Photos"
    static var description = IntentDescription("Backs up new photos to your Telegram library for about 25 seconds without opening Lelvo. Use it in a Camera automation so new photos go up within a minute.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let env = AppEnvironment.shared
        let started = Date()
        // Runs every time Camera closes, so it has to cost almost nothing when there is nothing to send: Photos' change
        // history instead of the whole library, and big videos don't count (a short run skips them; overnight sends them).
        env.engine.queueNewPhotos()
        if env.engine.readyCount(shortRun: true) == 0 {
            recordRun(.shortcut, started: started, summary: BackupEngine.Summary())
            let text = env.engine.readyCount() == 0
                ? "Everything is backed up."
                : "New photos are backed up. Big videos go up when you open Lelvo or overnight."
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        }
        env.td.start()
        // Shortcuts gives intents limited time: upload for ~25 s (photos and small videos), then the background runs and
        // the next one continue where this stopped. The queue is persistent, so nothing is lost.
        let summary = await env.engine.run(deadline: Date().addingTimeInterval(25), includeNew: true, shortRun: true)
        recordRun(.shortcut, started: started, summary: summary)
        BackgroundTasks.scheduleAll()
        return .result(value: summary.text, dialog: IntentDialog(stringLiteral: summary.text))
    }
}

struct BackupStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Backup Status"
    static var description = IntentDescription("Reports how many items are backed up, pending, failed, or too large.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let env = AppEnvironment.shared
        let counts = (try? env.store.counts()) ?? [:]
        let pending = (counts[.queued] ?? 0) + (counts[.uploading] ?? 0)
        var text = "\(counts[.backedUp] ?? 0) backed up, \(pending) pending"
        if let failed = counts[.failed], failed > 0 { text += ", \(failed) failed" }
        text += "."
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// iOS requires the user to confirm photo deletion, so this opens the app on the Free Up Space screen.
struct FreeUpSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Free Up Space"
    static var description = IntentDescription("Opens Lelvo on the Free Up Space screen.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.openFreeUpSpace()
        return .result()
    }
}

struct LelvoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BackUpNewPhotosIntent(),
                    phrases: ["Back up new photos with \(.applicationName)", "\(.applicationName) backup"],
                    shortTitle: "Back Up New Photos", systemImageName: "icloud.and.arrow.up")
        AppShortcut(intent: BackupStatusIntent(),
                    phrases: ["\(.applicationName) backup status"],
                    shortTitle: "Backup Status", systemImageName: "chart.bar")
        AppShortcut(intent: FreeUpSpaceIntent(),
                    phrases: ["Free up space with \(.applicationName)"],
                    shortTitle: "Free Up Space", systemImageName: "internaldrive")
    }
}
