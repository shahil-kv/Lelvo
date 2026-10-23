import XCTest

/// Launch-level smoke tests: first launch without any configuration (#18), onboarding, and
/// scrolling a large gallery without hanging.
final class SmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFirstLaunchWithoutConfigShowsOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        let start = app.buttons["Get started"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "Welcome screen should appear on a fresh install")
        start.tap()
        XCTAssertTrue(app.textFields["api_id"].waitForExistence(timeout: 10), "API credentials step should follow")
        XCTAssertTrue(app.buttons["Continue"].exists)
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "Continue stays disabled until credentials are entered")
    }

    func testGalleryScrollsLargeLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestDemoLibrary"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30))
        // Find the grid by identifier: the element type of a SwiftUI ScrollView varies between iOS versions.
        let scroll = app.descendants(matching: .any).matching(identifier: "galleryGrid").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 30))
        for _ in 0..<6 { scroll.swipeUp(velocity: .fast) }
        for _ in 0..<3 { scroll.swipeDown(velocity: .fast) }
        XCTAssertEqual(app.state, .runningForeground)
        app.tabBars.buttons["Albums"].tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
    }
}
