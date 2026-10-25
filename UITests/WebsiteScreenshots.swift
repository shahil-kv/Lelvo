import XCTest

/// Screenshots for the website (website/img). Not part of the normal test run: it needs real photos in the
/// simulator's library and only does anything when `CG_SCREENSHOT_DIR` is set. Run it with Scripts/website-shots.sh.
final class WebsiteScreenshots: XCTestCase {
    private var dir: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        dir = ProcessInfo.processInfo.environment["CG_SCREENSHOT_DIR"]
        try XCTSkipIf(dir == nil, "Set CG_SCREENSHOT_DIR (TEST_RUNNER_CG_SCREENSHOT_DIR) to take website screenshots")
    }

    private func shot(_ name: String) {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func settle(_ seconds: TimeInterval = 1.5) { Thread.sleep(forTimeInterval: seconds) }

    private func launchLibrary(columns: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoFromPhotos", "-gridColumns", "\(columns)"]
        app.launch()
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 30))
        settle(3)
        return app
    }

    func testLibraryScreens() {
        let app = launchLibrary(columns: 4)
        let grid = app.collectionViews["galleryGrid"]
        shot("timeline")

        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        settle(2.5)
        shot("viewer")
        app.buttons["Info"].tap()
        settle(1.5)
        shot("info")
        app.swipeDown(velocity: .fast)
        settle()
        app.buttons["Close"].tap()
        settle()

        app.buttons["Select"].tap()
        for i in [0, 2, 3, 7] { grid.cells.element(boundBy: i).tap() }
        settle()
        shot("select")
        app.buttons["Done"].tap()

        app.buttons["Albums"].firstMatch.tap()
        settle(2)
        shot("albums")
        app.buttons["Backup"].firstMatch.tap()
        settle(3)
        shot("backup")
        app.buttons["Settings"].firstMatch.tap()
        settle(2)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Backup options")).firstMatch.tap()
        settle(1.5)
        shot("backup-options")
    }

    func testDenseTimelineAndDarkMode() {
        let app = launchLibrary(columns: 5)
        shot("timeline-dark")
        app.buttons["Grid size"].tap()
        settle(1)
        app.buttons["What the icons mean"].tap()
        settle(1.5)
        shot("icons-dark")
    }

    func testWelcome() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        XCTAssertTrue(app.buttons["Continue with Telegram"].waitForExistence(timeout: 20))
        settle(2.5)
        shot("welcome")
        app.buttons["Continue with Telegram"].tap()
        settle(2)
        shot("signin")
    }
}
