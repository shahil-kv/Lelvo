import XCTest

/// Test plan Phase 11, device A ("Lelvo QA" simulator). Device B is the "Lelvo 40k" simulator, signed in to the same
/// library with backup forced off; the runner compares both local indexes afterwards. Skipped unless `QA_DIR` is set.
final class RealAccountSyncTests: XCTestCase {
    private var app: XCUIApplication!
    private var grid: XCUIElement { app.collectionViews["galleryGrid"] }
    private func note(_ s: String) { print("QA sync: \(s)") }
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }

    private func start() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        app = XCUIApplication()
        app.launchArguments = ["-autoBackup", "NO", "-backupPaused", "YES"]
        app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
    }

    private func select(_ i: Int) {
        app.buttons["Select"].tap()
        let cell = grid.cells.element(boundBy: i)
        note("cell \(i): \(cell.label)")
        cell.tap()
    }

    /// 11.1 favorite, 11.2 album, 11.3 delete to Recently Deleted, each on a different photo.
    func testSyncA_changes() throws {
        try start()
        select(0)
        app.buttons["More"].tap()
        let fav = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Favorite")).firstMatch
        XCTAssertTrue(fav.waitForExistence(timeout: 5)); fav.tap()
        sleep(2)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].firstMatch.tap() }
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }
        shot("A-favorite")

        select(1)
        app.buttons["More"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add to Album")).firstMatch.tap()
        XCTAssertTrue(app.buttons["New Album…"].waitForExistence(timeout: 5)); app.buttons["New Album…"].tap()
        let alert = app.alerts["New Album"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText("QA Sync")
        alert.buttons.matching(NSPredicate(format: "label != 'Cancel'")).firstMatch.tap()
        sleep(3); shot("A-album")
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }

        select(2)
        app.buttons["Delete"].tap()
        let everywhere = app.buttons["Delete Everywhere"]
        XCTAssertTrue(everywhere.waitForExistence(timeout: 5)); everywhere.tap()
        // iOS asks before the phone copy goes.
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for a in [app.alerts.firstMatch, spring.alerts.firstMatch] where a.waitForExistence(timeout: 8) {
            a.buttons["Delete"].tap(); break
        }
        sleep(15) // notes go out paced
        shot("A-deleted")
    }

    /// 11.2 again, on a photo that is in the library (cell 0 is backed up).
    func testSyncA_album() throws {
        try start()
        select(0)
        app.buttons["More"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add to Album")).firstMatch.tap()
        XCTAssertTrue(app.buttons["New Album…"].waitForExistence(timeout: 5)); app.buttons["New Album…"].tap()
        let alert = app.alerts["New Album"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText("QA Sync")
        alert.buttons.matching(NSPredicate(format: "label != 'Cancel'")).firstMatch.tap()
        sleep(15); shot("A-album-cloud")
    }

    /// 11.4 on device B: recover what A deleted.
    func testSyncB_recover() throws {
        try start()
        app.buttons["Collections"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recently Deleted")).firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        note("row: \(row.label)")
        row.tap()
        let all = app.buttons["Recover All"]
        XCTAssertTrue(all.waitForExistence(timeout: 10)); all.tap()
        XCTAssertTrue(app.staticTexts["No Recently Deleted Items"].waitForExistence(timeout: 15))
        sleep(15); shot("B-recovered")
    }
}
