import XCTest

/// QA hand-off: from the library step, creates a new encrypted library named `QA_NEW_LIBRARY` with the passphrase in
/// `QA_DIR`/new-pass.txt, then writes its recovery key next to it (`QA_DIR`/new-key.txt; `build/` is never committed).
/// Skipped unless `QA_NEW_LIBRARY` is set.
final class RealAccountNewLibraryTests: XCTestCase {
    func testCreateLibrary() throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["QA_NEW_LIBRARY"], let dir = env["QA_DIR"],
              let pass = try? String(contentsOfFile: dir + "/new-pass.txt", encoding: .utf8) else { throw XCTSkip("not set") }
        let app = XCUIApplication()
        app.launchArguments = ["-QAPlainFields"]  // no password AutoFill, so typing reaches the fields (I7)
        app.launch()
        let start = app.buttons["Start a new library instead"]
        if !start.waitForExistence(timeout: 10) {
            app.buttons["Back"].firstMatch.tap()   // back from the unlock step
        }
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let nameField = app.textFields["Library name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + name)
        let p1 = app.secureTextFields["Passphrase (10+ characters)"], p2 = app.secureTextFields["Repeat passphrase"]
        // Secure fields with password AutoFill can drop text typed into the element; type into the focused app instead.
        for field in [p1, p2] {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            sleep(1)
            if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap(); field.tap() }
            app.typeText(pass)
        }
        app.buttons["I understand. I'll keep both safe."].tap()
        // What the screen says now (a passphrase problem shows as text), for the tester.
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        try? texts.write(toFile: dir + "/screen-texts.txt", atomically: true, encoding: .utf8)
        app.buttons["Create library"].tap()
        let key = app.descendants(matching: .any)["Recovery key"]
        XCTAssertTrue(key.waitForExistence(timeout: 90), "The recovery key should be shown once")
        let value = (key.value as? String ?? "").replacingOccurrences(of: " ", with: "-")
        try value.write(toFile: dir + "/new-key.txt", atomically: true, encoding: .utf8)
        app.buttons["I've saved it"].tap()
        sleep(5)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
}
