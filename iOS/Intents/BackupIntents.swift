import AppIntents
import Foundation
import MemvoCore

/// Runs without opening the app: queues new photos as background uploads and reports what it did.
struct BackUpNewPhotosIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up New Photos"
    static var description = IntentDescription("Uploads new photos and videos to your Telegram library for about 25 seconds without opening the app; the rest continues later.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let env = AppEnvironment.shared
        env.td.start()
        // Shortcuts gives intents limited time: upload for ~25 s, then the overnight task and the
        // next run continue where this one stopped (nothing is lost; the queue is persistent).
        // A Shortcut the user set up is a deliberate "Back up now".
        let summary = await env.engine.run(deadline: Date().addingTimeInterval(25), includeNew: true)
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
    static var description = IntentDescription("Opens Memvo on the Free Up Space screen.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.openFreeUpSpace()
        return .result()
    }
}

struct MemvoShortcuts: AppShortcutsProvider {
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
