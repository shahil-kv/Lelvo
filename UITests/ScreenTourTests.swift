import XCTest

/// Walks the first-run screens and saves a screenshot of each, so light and dark mode can be checked without
/// tapping through by hand. `Scripts/screen-tour.sh` runs it once per appearance.
final class ScreenTourTests: XCTestCase {
    private var dir: URL?
    private var index = 0

    override func setUp() {
        continueAfterFailure = false
        dir = ProcessInfo.processInfo.environment["CG_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func shot(_ name: String) {
        index += 1
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir {
            try? png.write(to: dir.appendingPathComponent(String(format: "%02d-%@.png", index, name)))
        } else {
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            a.name = name; a.lifetime = .keepAlways; add(a)
        }
    }

    func testOnboardingTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        let start = app.buttons["Get started"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        sleep(1); shot("intro-hook")
        start.tap()
        let next = app.buttons["Continue"], last = app.buttons["Continue to Lelvo"]
        var page = 1
        while next.waitForExistence(timeout: 5), !last.exists, page < 6 {
            sleep(1); shot("intro-\(page)"); page += 1
            next.tap()
        }
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        sleep(1); shot("intro-\(page)")
        last.tap()
        let signIn = app.buttons["Continue with Telegram"], notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 3), !signIn.exists { sleep(1); shot("photos-ask"); notNow.tap() } else { signIn.tap() }

        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 15))
        sleep(1); shot("phone-empty")
        let dial = app.textFields["Country code"]
        dial.tap()
        dial.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1")
        phone.tap()
        // A keyboard suggestion chip gives the number with its country code and no plus.
        phone.typeText("15550100199")
        XCTAssertEqual(phone.value as? String, "5550100199", "The country code in a pasted number is split off")
        shot("phone-filled")
        app.buttons["Continue"].tap()

        let code = app.textFields["Login code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        sleep(1); shot("code")
        code.typeText("24680")
        let allow = app.buttons["Allow Access"], begin = app.buttons["Start using Lelvo"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15) || begin.exists)
        sleep(1); shot("after-code")
    }
}
