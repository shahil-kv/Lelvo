import XCTest

/// How the app holds up with a very large library: 100,000 sample items. Prints timings, and fails only if a screen
/// doesn't answer at all. Not part of the everyday run's meaning of "fast": a simulator on a Mac is not an iPhone.
final class ScaleTests: XCTestCase {
    func testOneHundredThousandItems() {
        let app = XCUIApplication()
        // Keep: seeding 100,000 items on launch is the test's own work, not the app's, so the first run after a reset
        // is slow and only later runs measure a normal launch.
        app.launchArguments = ["-UITestDemoLibrary", "-UITestDemoCount", "100000", "-UITestDemoAlbums", "-UITestDemoKeep"]
        func timed(_ name: String, _ step: () -> Void) {
            let start = Date()
            step()
            print(String(format: "SCALE %@: %.1f s", name, Date().timeIntervalSince(start)))
        }
        let grid = app.collectionViews["galleryGrid"]
        timed("launch to grid") {
            app.launch()
            XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 300))
        }
        timed("scroll 5 swipes") { for _ in 0..<5 { grid.swipeUp(velocity: .fast) } }
        timed("open and close viewer") {
            grid.cells.element(boundBy: 1).tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 60))
            app.buttons["Close"].tap()
        }
        timed("Collections tab") {
            app.buttons["Collections"].firstMatch.tap()
            // A day's cover near the top: the sections are counted, and the page isn't just a title.
            let day = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", " items")).firstMatch
            XCTAssertTrue(day.waitForExistence(timeout: 180))
        }
        timed("Search tab, type video") {
            app.buttons["Search"].firstMatch.tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 60))
            field.tap()
            field.typeText("video")
            XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 120))
            // The keyboard hides the tabs.
            field.buttons["Clear text"].tap()
            let close = app.buttons["Close"]
            if close.waitForExistence(timeout: 10) { close.tap() }
        }
        timed("Backup tab") {
            app.buttons["Backup"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 180))
            XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 60) || app.buttons["Failed"].exists)
        }
    }
}
