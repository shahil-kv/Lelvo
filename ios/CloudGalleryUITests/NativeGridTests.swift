import XCTest

/// Drives the photo grid like a person would: open and close the viewer, select with the button, long-press and
/// swipe-to-select, pinch to change columns, scrub dates, and scroll fast. Screenshots go to the test results, and
/// to `CG_SCREENSHOT_DIR` when set (`TEST_RUNNER_CG_SCREENSHOT_DIR=… xcodebuild test`).
final class NativeGridTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "600"]
        app.launch()
    }

    private var grid: XCUIElement { app.collectionViews["galleryGrid"] }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["CG_SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Section headers read "<title>, <n> items" to VoiceOver.
    private func header(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "\(title),")).firstMatch
    }

    private func waitForGrid() {
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "Grid should appear")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "Grid should have tiles")
    }

    func testOpenViewerSwipeAndClose() {
        waitForGrid()
        shot("01-grid")
        grid.cells.element(boundBy: 2).tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Tapping a tile opens the viewer")
        shot("02-viewer")
        app.swipeLeft()
        shot("03-viewer-next")
        close.tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        XCTAssertFalse(close.waitForExistence(timeout: 2), "Viewer closed")
        shot("04-back-to-grid")
    }

    func testSelectButtonAndSelectionBar() {
        waitForGrid()
        app.buttons["Select"].tap()
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        grid.cells.element(boundBy: 5).tap()
        XCTAssertTrue(app.staticTexts["3"].waitForExistence(timeout: 5), "Selection bar counts 3")
        shot("05-selected-3")
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 5), "Tapping again deselects")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))
        shot("06-select-done")
    }

    func testLongPressStartsSelectingAndSwipeSelects() {
        waitForGrid()
        grid.cells.element(boundBy: 0).press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "Long-press starts selecting")
        XCTAssertTrue(app.staticTexts["1"].waitForExistence(timeout: 5))
        // Photos' swipe-to-select: drag across a row.
        let from = grid.cells.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = grid.cells.element(boundBy: 3).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
        shot("07-swipe-select")
        app.buttons["Done"].tap()
    }

    func testPinchChangesColumns() {
        waitForGrid()
        let before = grid.cells.firstMatch.frame.width
        // Pinch in the middle of the screen (the grid runs under the tab bar, which takes touches there).
        // Two pinches: 4 → 5 → 6 columns (a quick synthetic pinch settles one step, like a short real one).
        grid.cells.element(boundBy: 9).pinch(withScale: 0.3, velocity: -2)
        grid.cells.element(boundBy: 9).pinch(withScale: 0.3, velocity: -2)
        let afterOut = grid.cells.firstMatch.frame.width
        XCTAssertLessThan(afterOut, before, "Pinching in shows more, smaller tiles")
        shot("08a-after-pinch")
        let monthFormatter = DateFormatter()
        monthFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        XCTAssertTrue(header(monthFormatter.string(from: Date())).waitForExistence(timeout: 5),
                      "At 6+ columns the timeline is grouped by month")
        shot("08-pinched-in")
        grid.cells.element(boundBy: 12).pinch(withScale: 3, velocity: 2)
        grid.cells.element(boundBy: 12).pinch(withScale: 3, velocity: 2)
        let afterIn = grid.cells.firstMatch.frame.width
        XCTAssertGreaterThan(afterIn, afterOut, "Pinching out shows fewer, bigger tiles")
        // The grid stays anchored on the tile under the fingers, so check the month headers are gone (day headers back).
        let month = header(monthFormatter.string(from: Date()))
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: month)], timeout: 5), .completed, "Back to day headers")
        shot("09-pinched-out")
    }

    func testFastScrollAndScrubber() {
        waitForGrid()
        for _ in 0..<5 { grid.swipeUp(velocity: .fast) }
        shot("10-scrolled")
        let scrubber = app.otherElements["Date scrubber"]
        if scrubber.waitForExistence(timeout: 3) {
            let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.3))
            start.press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)))
            shot("11-scrubbed")
        }
        for _ in 0..<5 { grid.swipeDown(velocity: .fast) }
        XCTAssertEqual(app.state, .runningForeground)
    }
}
