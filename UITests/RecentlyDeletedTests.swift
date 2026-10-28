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
        let begin = app.buttons["Start using Memvo"]
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
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", before - 1), object: grid.cells)
        wait(for: [gone], timeout: 15)

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
}
