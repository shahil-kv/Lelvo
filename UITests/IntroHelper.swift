import XCTest

extension XCUIApplication {
    /// Walks through the first-run intro to the Telegram sign-in, the way a user would: the pages, then "Not now"
    /// on Photos access when it hasn't been decided yet.
    func passIntro(file: StaticString = #filePath, line: UInt = #line) {
        let start = buttons["Get started"]
        XCTAssertTrue(start.waitForExistence(timeout: 20), "The intro should open on a fresh install", file: file, line: line)
        start.tap()
        let next = buttons["Continue"], last = buttons["Continue to Memvo"]
        for _ in 0..<3 where next.waitForExistence(timeout: 5) && !last.exists { next.tap() }
        XCTAssertTrue(last.waitForExistence(timeout: 5), file: file, line: line)
        last.tap()
        let signIn = buttons["Continue with Telegram"], notNow = buttons["Not now"]
        if notNow.waitForExistence(timeout: 3), !signIn.exists { notNow.tap() } else { signIn.tap() }
    }
}
