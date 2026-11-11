import XCTest

extension XCUIApplication {
    /// Walks through the first-run intro to the Telegram sign-in, the way a user would: the pages, then "Not now"
    /// on Photos access when it hasn't been decided yet.
    func passIntro(file: StaticString = #filePath, line: UInt = #line) {
        let start = buttons["Get started"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "The intro should open on a fresh install", file: file, line: line)
        start.tap()
        let next = buttons["Continue"], last = buttons["Continue to Lelvo"]
        for _ in 0..<3 where next.waitForExistence(timeout: 5) && !last.exists { next.tap() }
        XCTAssertTrue(last.waitForExistence(timeout: 5), file: file, line: line)
        last.tap()
        let signIn = buttons["Continue with Telegram"], notNow = buttons["Not now"]
        if notNow.waitForExistence(timeout: 3), !signIn.exists { notNow.tap() } else { signIn.tap() }
    }

    /// The App Review sign-in (reserved number and code) into the bundled sample library.
    func openDemoLibrary(file: StaticString = #filePath, line: UInt = #line) {
        passIntro(file: file, line: line)
        let phone = textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 15), file: file, line: line)
        let dial = textFields["Country code"]
        dial.tap()
        dial.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1")
        phone.tap()
        phone.typeText("5550100199")
        buttons["Continue"].tap()
        let code = textFields["Login code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), file: file, line: line)
        code.typeText("24680")
        let allow = buttons["Allow Access"]
        let begin = buttons["Start using Lelvo"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10) || begin.exists, file: file, line: line)
        if allow.exists {
            allow.tap()
            let dontAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if dontAllow.waitForExistence(timeout: 30) { dontAllow.tap() }
        }
        XCTAssertTrue(begin.waitForExistence(timeout: 15), file: file, line: line)
        begin.tap()
    }
}
