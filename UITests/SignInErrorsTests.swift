import XCTest

/// Test plan 2.2 (wrong login code says so and lets you try again) with the App Review number, and 7.14 (keep awake
/// switch) on the demo library.
final class SignInErrorsTests: XCTestCase {
    func test2_2_wrongCodeSaysSoAndRetries() {
        let app = XCUIApplication(); app.launchArguments = ["-UITestReset"]; app.launch()
        app.passIntro()
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 15))
        let dial = app.textFields["Country code"]; dial.tap()
        dial.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1")
        phone.tap(); phone.typeText("5550100199")
        app.buttons["Continue"].tap()
        let code = app.textFields["Login code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.typeText("11111")
        sleep(3)
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { $0.lowercased().contains("code") }
        print("QA wrong code:", texts)
        XCTAssertTrue(texts.contains { $0.lowercased().contains("isn't right") || $0.lowercased().contains("wrong") || $0.lowercased().contains("didn't work") || $0.lowercased().contains("invalid") || $0.lowercased().contains("try again") }, "Says the code is wrong")
        XCTAssertTrue(code.exists, "Stays on the code step to try again")
        code.tap(); code.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "24680")
        XCTAssertTrue(app.buttons["Start using Lelvo"].waitForExistence(timeout: 15) || app.buttons["Allow Access"].exists, "The right code then works")
    }

    func test7_14_keepAwakeSwitch() {
        let app = XCUIApplication(); app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "600"]; app.launch()
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 30))
        app.buttons["Backup"].firstMatch.tap()
        let s = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Keep iPhone awake'")).firstMatch
        for _ in 0..<6 where !s.isHittable { app.swipeUp() }
        XCTAssertTrue(s.waitForExistence(timeout: 10))
        let before = s.value as? String
        (s.switches.firstMatch.exists ? s.switches.firstMatch : s).tap()
        XCTAssertNotEqual(s.value as? String, before, "Keep awake switches")
        (s.switches.firstMatch.exists ? s.switches.firstMatch : s).tap()
    }
}
