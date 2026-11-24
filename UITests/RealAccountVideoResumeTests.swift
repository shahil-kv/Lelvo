import XCTest

/// Test plan 4.16 on the real "Lelvo QA" library: leave the 10-minute cloud video halfway, open it again, and it
/// starts near the same time.
final class RealAccountVideoResumeTests: XCTestCase {
    func test4_16_resumesNearSameTime() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        func open() {
            app.buttons["Search"].firstMatch.tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
            field.typeText("D8-10min")
            let cell = app.collectionViews["galleryGrid"].cells.firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 15), "Search finds the 10-minute video"); cell.tap()
        }
        open()
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 30))
        sleep(5)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        sleep(6)
        let left = slider.normalizedSliderPosition
        print("QA left at:", left, slider.value ?? "")
        app.buttons["Close"].firstMatch.tap()
        sleep(2)
        // Back on the search results: open the same video again.
        let cell = app.collectionViews["galleryGrid"].cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10)); cell.tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 30))
        sleep(5)
        let back = slider.normalizedSliderPosition
        print("QA reopened at:", back, slider.value ?? "")
        XCTAssertGreaterThan(back, 0.4, "Starts near where it was left")
    }

    /// Test plan 4.5: open cloud-only photos; the app log's "Photo timing" lines show screen copy then sharp.
    func test4_5_cloudPhotosOpen() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        app.buttons["Collections"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Only in the Cloud' OR label BEGINSWITH 'Only in the cloud'")).firstMatch
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        let photo = grid.cells.matching(NSPredicate(format: "NOT (label BEGINSWITH 'Video')")).firstMatch
        photo.tap()
        sleep(8)
        for _ in 0..<3 { app.swipeLeft(); sleep(6) }
    }
}
