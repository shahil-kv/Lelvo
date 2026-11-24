import XCTest

/// Test plan 10.1, 10.2, 10.5, 10.13 on the demo library: Settings shows who, which library and the version, and a
/// backup option survives a relaunch.
final class SettingsPersistTests: XCTestCase {
    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (reset ? ["-UITestReset"] : []) + ["-UITestDemoLibrary", "-UITestDemoCount", "600"]
        app.launch()
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 30))
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    private func openBackupOptions(_ app: XCUIApplication) {
        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Backup options'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Backup options row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Backup options"].waitForExistence(timeout: 5))
    }

    private func wifiSwitch(_ app: XCUIApplication) -> XCUIElement {
        let s = app.switches["Wi-Fi only"].firstMatch
        for _ in 0..<6 where !s.isHittable { app.swipeUp() }
        XCTAssertTrue(s.waitForExistence(timeout: 5), "Wi-Fi only toggle")
        return s
    }

    private func isOn(_ s: XCUIElement) -> Bool { (s.value as? String) == "1" }

    func testRowsShownAndOptionSurvivesRelaunch() {
        var app = launch(reset: true)
        openSettings(app)
        for label in ["Library", "Encryption"] {
            XCTAssertTrue(app.staticTexts[label].firstMatch.exists || app.descendants(matching: .any)[label].firstMatch.exists, "\(label) row")
        }
        let about = app.buttons["About & licenses"].firstMatch
        for _ in 0..<10 where !about.isHittable { app.swipeUp() }
        about.tap()
        let version = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Version'")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5), "Version row")
        print("QA settings version:", version.label)
        app.navigationBars.buttons.firstMatch.tap()
        for _ in 0..<8 { app.swipeDown() }
        openBackupOptions(app)
        let before = isOn(wifiSwitch(app))
        wifiSwitch(app).switches.firstMatch.exists ? wifiSwitch(app).switches.firstMatch.tap() : wifiSwitch(app).tap()
        XCTAssertNotEqual(isOn(wifiSwitch(app)), before, "Toggle changed")
        app.terminate()

        app = launch(reset: false)
        openSettings(app)
        openBackupOptions(app)
        XCTAssertNotEqual(isOn(wifiSwitch(app)), before, "Wi-Fi only kept after relaunch")
        wifiSwitch(app).switches.firstMatch.exists ? wifiSwitch(app).switches.firstMatch.tap() : wifiSwitch(app).tap()
    }

    /// Test plan 5.14: a Memories setting survives a relaunch.
    func testMemoriesSettingSurvivesRelaunch() {
        func trips(_ app: XCUIApplication) -> XCUIElement {
            openSettings(app)
            let row = app.buttons["Memories"].firstMatch
            for _ in 0..<6 where !row.isHittable { app.swipeUp() }
            row.tap()
            let t = app.switches["Trips"].firstMatch
            XCTAssertTrue(t.waitForExistence(timeout: 5), "Trips toggle")
            return t
        }
        var app = launch(reset: true)
        var t = trips(app)
        let before = isOn(t)
        (t.switches.firstMatch.exists ? t.switches.firstMatch : t).tap()
        XCTAssertNotEqual(isOn(t), before, "Toggle changed")
        app.terminate()
        app = launch(reset: false)
        t = trips(app)
        XCTAssertNotEqual(isOn(t), before, "Trips kept after relaunch")
        (t.switches.firstMatch.exists ? t.switches.firstMatch : t).tap()
    }
}
