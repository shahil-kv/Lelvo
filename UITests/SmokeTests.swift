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
        let start = app.buttons["Continue with Telegram"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "Welcome screen should appear on a fresh install")
        start.tap()
        // Sign-in starts at the phone number, like Telegram's own apps. Without built-in app keys a real number
        // asks for keys next; the App Review demo number works either way.
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 15), "Phone number should follow")
        if let dir = ProcessInfo.processInfo.environment["CG_SCREENSHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("signin-first-step.png"))
        }
        XCTAssertTrue(app.buttons["Continue"].exists)
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "Continue stays disabled until the field is filled in")
    }

    func testGalleryScrollsLargeLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestDemoLibrary"]
        app.launch()
        // iOS 26+ tab bars are not exposed as tabBars to XCUITest, so match the tab buttons directly.
        XCTAssertTrue(app.buttons["Photos"].firstMatch.waitForExistence(timeout: 30))
        // Find the grid by identifier: the element type of a SwiftUI ScrollView varies between iOS versions.
        let scroll = app.descendants(matching: .any).matching(identifier: "galleryGrid").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 30))
        for _ in 0..<6 { scroll.swipeUp(velocity: .fast) }
        for _ in 0..<3 { scroll.swipeDown(velocity: .fast) }
        XCTAssertEqual(app.state, .runningForeground)
        app.buttons["Albums"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 20))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
    }
}
