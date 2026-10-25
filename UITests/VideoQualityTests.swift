import XCTest

/// The quality pill on cloud videos with a fast version: shows what plays and switches at any time (issue #10).
/// Runs on the App Review demo library, whose sample videos stand in for both versions.
final class VideoQualityTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
    }

    private func screenshot(_ name: String) {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["CG_SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// The reviewer sign-in from `DemoModeTests`.
    private func openDemoLibrary() {
        let start = app.buttons["Continue with Telegram"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
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
        let begin = app.buttons["Start using Memvo"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10) || begin.exists)
        if allow.exists {
            allow.tap()
            let dontAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if dontAllow.waitForExistence(timeout: 5) { dontAllow.tap() }
        }
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        begin.tap()
    }

    func testSwitchBetweenOriginalAndCopy() {
        openDemoLibrary()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        let video = grid.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Video")).firstMatch
        for _ in 0..<6 where !video.exists { grid.swipeUp() }
        XCTAssertTrue(video.waitForExistence(timeout: 5), "The demo library has a video")
        video.tap()

        // Not measured yet: Telegram's usual ~1 MB/s can't carry the original, so the fast version plays first.
        let pill = app.buttons["Video quality"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertEqual(pill.value as? String, "Fast version")
        sleep(2)
        screenshot("video-quality-fast")

        // Switch to the original at any time…
        pill.tap()
        let original = app.buttons["Play Original Quality"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        screenshot("video-quality-menu")
        original.tap()
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Original"), object: pill)
        wait(for: [switched], timeout: 10)
        sleep(2)
        screenshot("video-quality-original")

        // …and back.
        pill.tap()
        app.buttons["Play Fast Version"].tap()
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Fast version"), object: pill)
        wait(for: [back], timeout: 10)
    }
}
