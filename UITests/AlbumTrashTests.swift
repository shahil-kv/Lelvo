import XCTest

/// Test plan 5.5 (delete an album, its photos stay) on the real "Lelvo QA" library, and 5.11 (Recently Deleted empties
/// itself after the retention) on the demo library with a 20-second retention.
final class AlbumTrashTests: XCTestCase {
    private func reveal(_ app: XCUIApplication, _ e: XCUIElement) {
        for _ in 0..<8 where !e.isHittable { app.swipeUp() }
    }

    func test5_5_deleteAlbumKeepsPhotos() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        app.buttons["Collections"].firstMatch.tap()
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA Sync,'")).firstMatch
        let all = app.buttons.matching(identifier: "See All").element(boundBy: 2)
        reveal(app, all); if all.exists { all.tap() }
        XCTAssertTrue(album.waitForExistence(timeout: 10), "QA Sync album listed")
        let photosBefore = album.label
        album.press(forDuration: 1.2)
        let menu = app.buttons["Delete Album"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        let confirm = app.alerts.buttons["Delete Album"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        // iOS asks before Photos deletes an album.
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Delete", "Delete Album"] where sb.buttons[label].waitForExistence(timeout: 4) { sb.buttons[label].tap(); break }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: album)
        wait(for: [gone], timeout: 20)
        print("QA album deleted:", photosBefore)
    }

    func test5_11_trashEmptiesAfterRetention() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "600", "-TestTrashRetentionSeconds", "20"]
        app.launch()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
        grid.cells.element(boundBy: 0).tap()
        let delete = app.buttons["Delete from cloud"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10)); delete.tap()
        app.alerts.buttons["Delete from Backup"].tap()
        sleep(2); if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        sleep(25)
        app.terminate()
        app.launchArguments = ["-UITestDemoLibrary", "-UITestDemoCount", "600", "-TestTrashRetentionSeconds", "20"]
        app.launch()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
        sleep(5)
        app.buttons["Collections"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Recently Deleted'")).firstMatch
        reveal(app, row)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        print("QA trash row:", row.label)
        row.tap()
        XCTAssertTrue(app.staticTexts["No Recently Deleted Items"].waitForExistence(timeout: 15), "Emptied after the retention")
    }

    /// Test plan 5.4 (I21): two backed-up photos into "QA Remove", then one taken out; the other stays.
    func test5_4_removeFromAlbum() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
        app.buttons["Select"].tap()
        grid.cells.element(boundBy: 0).tap(); grid.cells.element(boundBy: 1).tap()
        app.buttons["More"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add to Album")).firstMatch.tap()
        XCTAssertTrue(app.buttons["New Album…"].waitForExistence(timeout: 5)); app.buttons["New Album…"].tap()
        let alert = app.alerts["New Album"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText("QA Remove 3")
        alert.buttons.matching(NSPredicate(format: "label != 'Cancel'")).firstMatch.tap()
        sleep(4)
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }

        app.buttons["Collections"].firstMatch.tap()
        let all = app.buttons.matching(identifier: "See All").element(boundBy: 2)
        reveal(app, all); if all.exists { all.tap() }
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA Remove 3, 2'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20), "QA Remove has 2")
        album.tap()
        let inner = app.collectionViews["galleryGrid"]
        XCTAssertTrue(inner.cells.firstMatch.waitForExistence(timeout: 15))
        app.buttons["Select"].tap(); inner.cells.element(boundBy: 0).tap()
        app.buttons["More"].tap()
        let remove = app.buttons["Remove from Album"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Remove from Album offered inside a user album")
        remove.tap()
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Remove", "Allow", "Modify"] where sb.buttons[label].waitForExistence(timeout: 4) { sb.buttons[label].tap(); break }
        let one = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: inner.cells)
        wait(for: [one], timeout: 20)
        sleep(15) // album note goes out paced
    }

    /// Test plan 3.17 then 3.18 on the two newest photos (just backed up): one removed from this iPhone only, the
    /// other deleted from the backup only (`QA_STEP=phone|backup`). The runner compares the Backup tab counts.
    func test3_17_18_deletePhoneOnlyThenBackupOnly() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        app.tabBars.buttons["Photos"].firstMatch.tap()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func pick(_ i: Int, _ button: String) {
            app.buttons["Select"].tap()
            // Newest photo that is both on this iPhone and backed up (dated test photos sort above "today").
            grid.cells.matching(NSPredicate(format: "label CONTAINS 'and in the cloud'")).element(boundBy: 0).tap()
            app.buttons["Delete"].tap()
            let b = app.buttons[button]
            XCTAssertTrue(b.waitForExistence(timeout: 5), button); b.tap()
            // iOS asks before a phone copy goes; deleting from the backup only has no second question.
            for a in [app.alerts.firstMatch, sb.alerts.firstMatch] where a.waitForExistence(timeout: 6) {
                if a.buttons["Delete"].exists { a.buttons["Delete"].tap() }
                break
            }
            sleep(8)
            if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }
        }
        let step = ProcessInfo.processInfo.environment["QA_STEP"] ?? "phone"
        pick(0, step == "phone" ? "Remove 1 from This iPhone" : "Delete 1 from Backup Only")
        sleep(10)
    }
}
