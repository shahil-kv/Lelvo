import XCTest

/// Deleting from the cloud moves the item to Recently Deleted, from where it can be recovered (issue #11).
/// Runs on the App Review demo library, so no Telegram account is needed.
final class RecentlyDeletedTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
    }

    private func screenshot(_ name: String) {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["CG_SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// The reviewer sign-in from `DemoModeTests`.
    private func openDemoLibrary() {
        app.passIntro()
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 15))
        let dial = app.textFields["Country code"]
        dial.tap()
        dial.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1")
        phone.tap()
        phone.typeText("5550100199")
        app.buttons["Continue"].tap()
        let code = app.textFields["Login code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.typeText("24680")
        let allow = app.buttons["Allow Access"]
        let begin = app.buttons["Start using Lelvo"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10) || begin.exists)
        if allow.exists {
            allow.tap()
            let dontAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if dontAllow.waitForExistence(timeout: 5) { dontAllow.tap() }
        }
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        begin.tap()
    }

    func testDeleteMovesToRecentlyDeletedAndRecovers() {
        openDemoLibrary()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        let before = grid.cells.count

        // Delete one cloud item from the viewer.
        grid.cells.element(boundBy: 0).tap()
        let delete = app.buttons["Delete from cloud"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        let confirm = app.alerts.buttons["Delete from Backup"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Recently Deleted")).firstMatch.exists)
        confirm.tap()
        // It waits in Collections → Recently Deleted with 30 days left.
        app.buttons["Collections"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recently Deleted, 1")).firstMatch
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "30 days left")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        screenshot("recently-deleted")

        // Recover All brings it back to the timeline.
        app.buttons["Recover All"].tap()
        XCTAssertTrue(app.staticTexts["No Recently Deleted Items"].waitForExistence(timeout: 10))
        screenshot("recently-deleted-empty")
        app.buttons["Photos"].firstMatch.tap()
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", before), object: grid.cells)
        wait(for: [back], timeout: 15)
    }

    /// Select, Done, Recover and Delete for one item, then Delete All, which asks first.
    func testEveryRecentlyDeletedButton() {
        openDemoLibrary()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<2 {
            grid.cells.element(boundBy: 0).tap()
            let delete = app.buttons["Delete from cloud"]
            XCTAssertTrue(delete.waitForExistence(timeout: 10))
            delete.tap()
            app.alerts.buttons["Delete from Backup"].tap()
            sleep(2)
            if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        }
        app.buttons["Collections"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recently Deleted, 2")).firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "Select switches to Done")
        app.buttons["Done"].tap()
        XCTAssertTrue(select.waitForExistence(timeout: 5))

        select.tap()
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "30 days left")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        XCTAssertTrue(app.buttons["Recover"].waitForExistence(timeout: 5), "With a selection the bar acts on it")
        app.buttons["Recover"].tap()
        let one = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", "30 days left"),
                                            object: tile)
        wait(for: [one], timeout: 10)
        sleep(1)

        app.buttons["Delete All"].tap()
        let confirm = app.buttons["Delete from Telegram"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete All asks first")
        screenshot("recently-deleted-confirm")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No Recently Deleted Items"].waitForExistence(timeout: 15), "Deleting empties it")
    }

    func testSwipeSelectsInRecentlyDeleted() {
        openDemoLibrary()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<4 {
            grid.cells.element(boundBy: 0).tap()
            let delete = app.buttons["Delete from cloud"]
            XCTAssertTrue(delete.waitForExistence(timeout: 10))
            delete.tap()
            let confirm = app.alerts.buttons["Delete from Backup"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            // The viewer can close by itself after a delete, between a check and a tap, so tap only if it stays open.
            let close = app.buttons["Close"]
            if close.exists, !close.waitForNonExistence(timeout: 3) { close.tap() }
            XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 10))
        }
        app.buttons["Collections"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recently Deleted, 4")).firstMatch
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let trash = app.collectionViews["trashGrid"]
        XCTAssertTrue(trash.cells.element(boundBy: 3).waitForExistence(timeout: 10))
        app.buttons["Select"].tap()
        let from = trash.cells.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = trash.cells.element(boundBy: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
        screenshot("recently-deleted-swipe")
        XCTAssertTrue(app.buttons["Recover"].waitForExistence(timeout: 5), "A swipe selects, so the bar acts on the selection")
        app.buttons["Recover"].tap()
        let left = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: trash.cells)
        wait(for: [left], timeout: 15)
    }

    func testToolsAnswerEveryTap() {
        openDemoLibrary()
        app.buttons["Backup"].firstMatch.tap()
        let rescan = app.buttons["Re-scan the Telegram library"]
        for _ in 0..<4 where !rescan.isHittable { app.swipeUp() }
        rescan.tap()
        XCTAssertTrue(app.staticTexts["Everything is up to date"].waitForExistence(timeout: 5), "Re-scan says what it found")
        screenshot("rescan-toast")

        app.buttons["Free up space"].tap()
        let check = app.buttons["Check what's safe to remove"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.tap()
        XCTAssertTrue(app.staticTexts["Nothing to check yet"].waitForExistence(timeout: 5), "The first tap answers, with nothing to check")
        screenshot("free-up-toast")
    }
}
