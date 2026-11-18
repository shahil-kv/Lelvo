import XCTest

/// QA on a real test library (docs/MANUAL_TEST_PLAN.md 1.20–1.22). Skipped unless `QA_DIR` is set. Uses the Debug-only
/// `-QA…` hooks in iOS/App/QAHooks.swift; the test only answers iOS's questions and waits.
final class RealAccountChangesTests: XCTestCase {
    private func launch(_ args: [String]) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        // A fresh sign-in ends on the last setup screen; finish it so the tabs show.
        if app.buttons["Start using Lelvo"].waitForExistence(timeout: 6) { app.buttons["Start using Lelvo"].tap() }
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        return app
    }

    /// Taps iOS's own confirmation (delete or modify) when it shows, from the app or SpringBoard.
    private func allow(_ labels: [String], within seconds: TimeInterval) {
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let until = Date().addingTimeInterval(seconds)
        var logged = false
        while Date() < until {
            for a in [XCUIApplication().alerts.firstMatch, spring.alerts.firstMatch] where a.exists {
                if !logged { print("QA alert buttons:", a.buttons.allElementsBoundByIndex.map(\.label)); logged = true }
                let yes = a.buttons.allElementsBoundByIndex.first { b in labels.contains { b.label.contains($0) } }
                if let yes { yes.tap(); return }
            }
            for l in labels {
                for b in [XCUIApplication().buttons[l], spring.buttons[l]] where b.exists { b.tap(); return }
            }
            sleep(1)
        }
    }

    private func backUpAndWait(_ app: XCUIApplication, during: () -> Void = {}) {
        let tab = app.buttons["Backup"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30)); tab.tap()
        let backUp = app.buttons["Back up now"]
        if backUp.waitForExistence(timeout: 20), backUp.isEnabled { backUp.tap() }
        during()
        let until = Date().addingTimeInterval(600)
        sleep(5)
        // Done once "Backing up" has been gone for three checks in a row (the button's state never settled under test).
        var idle = 0
        while Date() < until, idle < 3 {
            let busy = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Backing up' OR label CONTAINS 'resuming in'")).firstMatch.exists
            idle = busy ? 0 : idle + 1
            sleep(3)
        }
        sleep(3); shot("after-backup")
    }

    func test1_20_deleteWhileQueued() throws {
        let app = try launch([])
        let tab = app.buttons["Backup"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30)); tab.tap()
        let backUp = app.buttons["Back up now"]
        if backUp.waitForExistence(timeout: 10), backUp.isEnabled { backUp.tap() }
        sleep(4)
        // Delete the 3 newest photos in Apple's Photos app while the run goes on.
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.activate()
        sleep(3)
        for _ in 0..<3 where photos.buttons["Continue"].exists { photos.buttons["Continue"].tap(); sleep(2) }
        shot("photos-open")
        let select = photos.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10)); select.tap()
        let cells = photos.images.allElementsBoundByIndex.filter(\.isHittable)
        for c in cells.suffix(3) { c.tap() }
        shot("photos-selected")
        let trash = photos.buttons["Delete"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5)); trash.tap()
        let confirm = photos.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Delete'")).allElementsBoundByIndex.last
        if let confirm, confirm.waitForExistence(timeout: 5) { confirm.tap() }
        sleep(2); shot("photos-deleted")
        app.activate()
        let until = Date().addingTimeInterval(600)
        // Done once "Backing up" has been gone for three checks in a row (the button's state never settled under test).
        var idle = 0
        while Date() < until, idle < 3 {
            let busy = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Backing up' OR label CONTAINS 'resuming in'")).firstMatch.exists
            idle = busy ? 0 : idle + 1
            sleep(3)
        }
        sleep(3); shot("after-backup")
    }

    func test1_21_editAfterBackup() throws {
        let app = try launch(["-QAEditNewestBackedUp"])
        allow(["Modify", "Allow"], within: 30)
        sleep(5)
        backUpAndWait(app)
    }

    func test1_22_freeUpAfterTelegramLoss() throws {
        let app = try launch(["-QADropNewestInTelegram"])
        sleep(20)
        app.terminate(); app.launchArguments = []; app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        sleep(15)
        let tab = app.buttons["Backup"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30)); tab.tap()
        let free = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Free Up'")).firstMatch
        if free.waitForExistence(timeout: 10) { free.tap() }
        sleep(8); shot("free-up")
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    // Test plan A2: Debug-only faults on file sends (Shared/Support/FaultInjection.swift). The runner adds fresh photos
    // first; Scripts/check-log.py then proves from the app log that the pause was kept and at most two ran at once.
    func testT1_floodWaitHonoured() throws {
        let app = try launch(["-QAFloodOnSend", "2", "25"])
        backUpAndWait(app)
    }

    func test7_3_dropThenRetry() throws {
        let app = try launch(["-QAFailSend", "1", "2"])
        backUpAndWait(app)
    }

    func testL4_offlineMidRun() throws {
        let app = try launch(["-QAOfflineFor", "3", "40"])
        // Retry waits show no "Backing up" text, so give the 40 s outage and the backoff after it a fixed window.
        backUpAndWait(app, during: { sleep(120) })
    }
}
