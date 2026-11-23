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
        // With Photos not asked yet, "Continue" goes straight to the system prompt (App Review 5.1.1(iv)), then sign-in.
        if app.buttons["Continue"].waitForExistence(timeout: 4) { sleep(1); shot("photos-page"); app.buttons["Continue"].tap() }
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 4) {
            sleep(1); shot("photos-ask")
            let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
            (deny.exists ? deny : alert.buttons.firstMatch).tap()
        } else if app.buttons["Continue with Telegram"].exists { app.buttons["Continue with Telegram"].tap() }

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

    /// Test plan 10.14 / 10.15: every main tab and Settings on the demo library, for light, dark and largest text.
    /// A sideways swipe that starts on a feature row or an FAQ row turns the page instead of only tapping the row.
    func testSwipeOnRowsTurnsPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 20))
        app.buttons["Get started"].tap()
        app.buttons["Continue"].tap()
        let row = app.staticTexts["Search your photos"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        sleep(1)
        XCTAssertFalse(row.exists && row.isHittable, "Swipe on a feature row turned the page")
        app.buttons["Continue"].tap()
        let faq = app.staticTexts["Can Telegram see my photos?"]
        XCTAssertTrue(faq.waitForExistence(timeout: 5))
        faq.swipeRight()
        sleep(1)
        XCTAssertFalse(faq.exists && faq.isHittable, "Swipe on an FAQ row turned the page back")
    }

    func testMainTabsTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        app.passIntro()
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 15))
        let dial = app.textFields["Country code"]
        dial.tap(); dial.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1")
        phone.tap(); phone.typeText("5550100199")
        app.buttons["Continue"].tap()
        let code = app.textFields["Login code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10)); code.typeText("24680")
        let allow = app.buttons["Allow Access"], begin = app.buttons["Start using Lelvo"]
        _ = allow.waitForExistence(timeout: 10)
        if allow.exists {
            allow.tap()
            let no = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if no.waitForExistence(timeout: 5) { no.tap() }
        }
        XCTAssertTrue(begin.waitForExistence(timeout: 10)); begin.tap()
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 15))
        sleep(2); shot("tab-photos")
        for tab in ["Collections", "Search", "Backup"] {
            app.buttons[tab].firstMatch.tap(); sleep(2); shot("tab-" + tab.lowercased())
        }
        let gear = app.buttons.matching(NSPredicate(format: "label == 'Settings'")).firstMatch
        if gear.waitForExistence(timeout: 5) {
            gear.tap(); sleep(2); shot("settings-top")
            app.swipeUp(); sleep(1); shot("settings-middle")
            app.swipeUp(); app.swipeUp(); sleep(1); shot("settings-bottom")
        }
    }
}
