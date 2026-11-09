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
        XCTAssertTrue(app.staticTexts["3 Selected"].waitForExistence(timeout: 5), "The title counts 3")
        shot("05-selected-3")
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["2 Selected"].waitForExistence(timeout: 5), "Tapping again deselects")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5))
        shot("06-select-done")
    }

    func testLongPressStartsSelectingAndSwipeSelects() {
        waitForGrid()
        // Four tiles in one row: the demo library's dates follow the clock, so a new day can start after any tile.
        let frames = (0..<30).map { grid.cells.element(boundBy: $0) }.prefix { $0.exists }.map(\.frame)
        let rowStart = frames.indices.first { i in
            i + 3 < frames.count && frames[i + 3].minY == frames[i].minY
        }
        guard let rowStart else { return XCTFail("A row of four tiles should be on screen") }
        grid.cells.element(boundBy: rowStart).press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "Long-press starts selecting")
        XCTAssertTrue(app.staticTexts["1 Selected"].waitForExistence(timeout: 5))
        // Photos' swipe-to-select: drag across a row.
        let from = grid.cells.element(boundBy: rowStart + 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = grid.cells.element(boundBy: rowStart + 3).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertTrue(app.staticTexts["4 Selected"].waitForExistence(timeout: 5), "The first tile and the three swiped over")
        shot("07-swipe-select")
        app.buttons["Done"].tap()
    }

    func testSwipeSelectsEveryTileBetweenAcrossRows() {
        waitForGrid()
        app.buttons["Select"].tap()
        // Ends at the far end of the next row, so the drag is mostly sideways and selects instead of scrolling. That needs a
        // next row of at least three tiles: the demo library's dates follow the clock, so which tile starts a new day changes.
        let frames = (0..<30).map { grid.cells.element(boundBy: $0) }.prefix { $0.exists }.map(\.frame)
        var start: Int?, nextRow = 0, last = 0
        for i in frames.indices where i == 0 || frames[i].minY != frames[i - 1].minY {
            let row = frames[i...].prefix { $0.minY == frames[i].minY }.count
            let next = frames[(i + row)...].prefix { $0.minY == frames[i + row].minY }.count
            if i + row < frames.count, next >= 3, i + row + next < frames.count {
                start = i
                nextRow = i + row
                last = i + row + next - 1
                break
            }
        }
        guard let start else { return XCTFail("Two rows to swipe across should be on screen") }
        let from = grid.cells.element(boundBy: start).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = grid.cells.element(boundBy: last).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
        let count = last - start + 1
        XCTAssertTrue(app.staticTexts["\(count) Selected"].waitForExistence(timeout: 5), "Every tile between, in timeline order, like Photos")
        shot("07b-swipe-across-rows")
        // Starting on a selected tile deselects. Two tiles side by side, as a short diagonal would scroll.
        let back = grid.cells.element(boundBy: nextRow).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        back.press(forDuration: 0.05, thenDragTo: grid.cells.element(boundBy: nextRow + 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(app.staticTexts["\(count - 2) Selected"].waitForExistence(timeout: 5), "A swipe from a selected tile deselects")
        app.buttons["Done"].tap()
    }

    func testPinchChangesColumns() {
        waitForGrid()
        let before = grid.cells.firstMatch.frame.width
        // Pinch in the middle of the screen (the grid runs under the tab bar, which takes touches there).
        // Each pinch moves one step, like Photos: 4 → 5 columns, then a second pinch 5 → 6 (grouped by month).
        grid.cells.element(boundBy: 9).pinch(withScale: 0.6, velocity: -2)
        let afterFirst = grid.cells.firstMatch.frame.width
        XCTAssertLessThan(afterFirst, before, "Pinching in shows more, smaller tiles")
        shot("08a-after-pinch")
        grid.cells.element(boundBy: 9).pinch(withScale: 0.6, velocity: -2)
        let afterOut = grid.cells.firstMatch.frame.width
        XCTAssertLessThan(afterOut, afterFirst, "A second pinch steps to the next size")
        let monthFormatter = DateFormatter()
        monthFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        XCTAssertTrue(header(monthFormatter.string(from: Date())).waitForExistence(timeout: 5),
                      "At 6+ columns the timeline is grouped by month")
        shot("08-pinched-in")
        grid.cells.element(boundBy: 12).pinch(withScale: 3, velocity: 2)
        let afterIn = grid.cells.firstMatch.frame.width
        XCTAssertGreaterThan(afterIn, afterOut, "Pinching out shows fewer, bigger tiles")
        // The grid stays anchored on the tile under the fingers, so check the month headers are gone (day headers back).
        let month = header(monthFormatter.string(from: Date()))
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: month)], timeout: 5), .completed, "Back to day headers")
        shot("09-pinched-out")
    }

    /// Scrolling right after a pinch moves the grid with the finger (no wait for the pinch to land, no snapping back).
    func testScrollRightAfterPinch() {
        waitForGrid()
        grid.cells.element(boundBy: 9).pinch(withScale: 0.6, velocity: -2)
        let cell = grid.cells.element(boundBy: 20)
        let label = cell.label
        let before = cell.frame.minY
        // An exact drag with a hold before lifting the finger: no momentum, so the distance doesn't depend on machine speed.
        let from = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let to = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        let same = grid.cells.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(same.exists, "A drag moves the grid with the finger, not a jump")
        XCTAssertLessThan(same.frame.minY, before - 100, "The grid scrolled up with the finger")
        shot("10-scroll-after-pinch")
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
