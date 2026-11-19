import XCTest

/// QA on a real test library (already unlocked on this simulator): "Back up now" and wait for the run to end.
/// Skipped unless `QA_DIR` is set. Screenshots of the Backup tab before and after.
final class RealAccountBackupTests: XCTestCase {
    func testBackUpNow() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["Start using Lelvo"]
        if start.waitForExistence(timeout: 8) { start.tap() }
        // First run: pick one photo and watch it arrive, like a new user.
        let first = app.buttons["Back up this photo"]
        if first.waitForExistence(timeout: 8) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
            shot("first-photo-picked")
            first.tap()
            sleep(45)
            shot("first-photo-sent")
            for label in ["Continue", "Done", "Start using Lelvo", "Skip for now", "Not now"] where app.buttons[label].exists {
                app.buttons[label].tap(); sleep(2)
            }
        }
        // The one-time "Found a bug?" note comes a few seconds after the photos first show.
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap(); sleep(1) }
        let tab = app.buttons["Backup"].firstMatch
        if !tab.waitForExistence(timeout: 30) { shot("no-backup-tab") }
        XCTAssertTrue(tab.exists)
        tab.tap()
        shot("before")
        let backUp = app.buttons["Back up now"]
        XCTAssertTrue(backUp.waitForExistence(timeout: 20))
        backUp.tap()
        // Done when the button is back and no run is going (up to 10 minutes).
        let until = Date().addingTimeInterval(600)
        sleep(5)
        while Date() < until {
            if backUp.exists, backUp.isEnabled, !app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Backing up'")).firstMatch.exists { break }
            sleep(3)
        }
        sleep(3)
        shot("after")
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
