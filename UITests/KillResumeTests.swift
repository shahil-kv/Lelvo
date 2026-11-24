import XCTest

/// Test plan 13.12: the app is killed on each main screen and opened again; it comes back without a crash.
final class KillResumeTests: XCTestCase {
    func testKillOnEveryMainScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "600"]
        app.launch()
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 30))
        app.launchArguments = ["-UITestDemoLibrary", "-UITestDemoCount", "600"]
        for tab in ["Photos", "Collections", "Search", "Backup", "Settings"] {
            if tab == "Settings" {
                app.buttons["Settings"].firstMatch.tap()
                XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
            } else {
                app.buttons[tab].firstMatch.tap()
            }
            sleep(2)
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["Photos"].firstMatch.waitForExistence(timeout: 30), "Back after a kill on \(tab)")
            XCTAssertEqual(app.state, .runningForeground, "Still running after reopening from \(tab)")
            if app.navigationBars["Settings"].exists { app.buttons["Done"].firstMatch.tap() }
        }
    }
}
