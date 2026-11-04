import XCTest

/// Section 4 of the button check: every button on the Backup tab. Runs on the App Review demo library, whose uploads
/// are simulated, so real uploads, Wi-Fi rules and removing photos from the phone are checked by hand on a device.
final class BackupButtonsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        openDemoLibrary()
        app.buttons["Backup"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 15))
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        let begin = app.buttons["Start using Lelvo"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10) || begin.exists)
        if allow.exists {
            allow.tap()
            let dontAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if dontAllow.waitForExistence(timeout: 5) { dontAllow.tap() }
        }
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        begin.tap()
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 15))
    }

    private func open(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable, "\(title) should be on the Backup tab", file: file, line: line)
        return row
    }

    func testBackUpNowPauseAndResume() {
        let backUp = app.buttons["Back up now"]
        XCTAssertTrue(backUp.waitForExistence(timeout: 10))
        backUp.tap()
        let pause = app.buttons["Pause backup"]
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "A running backup can be paused")
        screenshot("backup-running")
        pause.tap()
        let resume = app.buttons["Resume backup"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "Pause offers Resume")
        screenshot("backup-paused")
        resume.tap()
        XCTAssertFalse(resume.waitForExistence(timeout: 3), "Resume starts it again")
    }

    func testKeepAwakeSwitch() {
        let toggle = app.switches["Keep iPhone awake while backing up"]
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.exists)
        let before = toggle.value as? String
        toggle.switches.firstMatch.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? ""), object: toggle)
        wait(for: [changed], timeout: 5)
    }

    func testFailedOpens() {
        open("Failed").tap()
        sleep(2)
        screenshot("failed")
        XCTAssertFalse(app.buttons["Back up now"].isHittable, "The Failed row opens its screen")
    }

    func testFreeUpSpaceButtonAnswers() {
        open("Free up space").tap()
        let check = app.buttons["Check what's safe to remove"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        screenshot("free-up-space")
        check.tap()
        sleep(2)
        screenshot("free-up-after-check")
    }

    func testSaveAllAsksFirst() {
        open("Save all to Photos").tap()
        XCTAssertTrue(app.navigationBars["Save All to Photos"].waitForExistence(timeout: 10))
        let save = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save ")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        sleep(2)
        screenshot("save-all")
        XCTAssertTrue(save.isEnabled, "Cloud items can be saved")
        save.tap()
        XCTAssertTrue(app.buttons["Save to Photos"].waitForExistence(timeout: 5), "It asks first")
    }

    func testShortcutsGuideOpens() {
        open("Shortcuts automations").tap()
        sleep(2)
        screenshot("shortcuts-guide")
        XCTAssertFalse(app.navigationBars["Backup"].exists && app.buttons["Back up now"].isHittable, "The guide opens")
    }

    func testRescanAnswers() {
        open("Re-scan the Telegram library").tap()
        XCTAssertTrue(app.staticTexts["Everything is up to date"].waitForExistence(timeout: 10), "Re-scan says what it found")
    }

    func testSettingsOpensFromBackup() {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 10))
    }
}
