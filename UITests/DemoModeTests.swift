import XCTest

/// The App Review demo, start to finish, exactly as a reviewer would use it (docs/APP_STORE_RELEASE.md, Phase 2):
/// reserved number and code → sample library with the banner → viewer → simulated backup → sign out.
final class DemoModeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testReviewerDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
        // A Photos prompt that came too late for an earlier attempt still covers the screen: answer it first.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let leftover = springboard.buttons["Don’t Allow"]
        if leftover.waitForExistence(timeout: 2) { leftover.tap() }

        let start = app.buttons["Continue with Telegram"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()

        // As the review notes say: country code 1, then 555 010 0199 (the number pad has no "+").
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 15), "The phone step comes first, even without built-in app keys")
        let dial = app.textFields["Country code"]
        dial.tap()
        dial.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1")
        phone.tap()
        phone.typeText("5550100199")
        app.buttons["Continue"].tap()

        let code = app.textFields["Login code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.typeText("24680")

        // Photos step: decline if asked (the simulator remembers an earlier answer), so the test doesn't depend on
        // the simulator's photos.
        let allow = app.buttons["Allow Access"]
        let begin = app.buttons["Start using Memvo"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10) || begin.exists)
        if allow.exists {
            allow.tap()
            // On a fresh CI simulator the system prompt took over 15 s to appear: the test gave up at 5 s, the app was
            // still waiting for the answer, and the late prompt then covered the retry.
            let dontAllow = springboard.buttons["Don’t Allow"]
            if dontAllow.waitForExistence(timeout: 30) { dontAllow.tap() }
        }
        XCTAssertTrue(begin.waitForExistence(timeout: 15))
        begin.tap()

        // The sample library, clearly marked as a demo.
        XCTAssertTrue(app.descendants(matching: .any)["demoBanner"].waitForExistence(timeout: 15))
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(grid.cells.count, 8)
        // The waiting items are dated today, so "Today" appears only once they're backed up.
        let today = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Today,")).firstMatch
        XCTAssertFalse(today.exists)

        // Viewer opens a sample.
        grid.cells.element(boundBy: 0).tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()

        // Simulated backup: the waiting items "upload" and join the library.
        app.buttons["Backup"].firstMatch.tap()
        let waiting = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "6 items not in the cloud")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "The demo's waiting items are counted")
        let backUp = app.buttons["Back up now"]
        XCTAssertTrue(backUp.exists)
        backUp.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: backUp)
        wait(for: [gone], timeout: 30)
        app.buttons["Photos"].firstMatch.tap()
        // All six arrive (the button hides as soon as the run starts, so some may still be uploading here).
        let allSix = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Today, 6 items")).firstMatch
        XCTAssertTrue(allSix.waitForExistence(timeout: 30), "The uploaded items join the timeline")

        // Settings shows the demo account; signing out returns to the welcome screen.
        app.buttons["Settings"].firstMatch.tap()
        let account = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Demo account")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        let signOut = app.buttons["Sign out and reset this iPhone"]
        for _ in 0..<6 where !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        app.alerts.buttons["Sign Out"].tap()
        XCTAssertTrue(app.buttons["Continue with Telegram"].waitForExistence(timeout: 20))
    }
}
