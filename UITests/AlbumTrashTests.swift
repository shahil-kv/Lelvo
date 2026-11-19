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
}
