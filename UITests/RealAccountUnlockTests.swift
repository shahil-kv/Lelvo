import XCTest

/// QA hand-off, after `RealAccountSignInTests`: restores the library named `QA_LIBRARY` and unlocks it with the key in
/// `QA_DIR`/key.txt, which is deleted as soon as it is read. Skipped unless `QA_LIBRARY` is set. Nothing is logged.
final class RealAccountUnlockTests: XCTestCase {
    func testUnlockLibrary() throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["QA_LIBRARY"], let dir = env["QA_DIR"] else { throw XCTSkip("QA_LIBRARY not set") }
        let path = dir + "/key.txt"
        let key = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        guard !key.isEmpty else { throw XCTSkip("No key") }

        let app = XCUIApplication()
        app.launchArguments = env["QA_ARGS"]?.split(separator: " ").map(String.init) ?? []
        app.launch()
        let field = app.secureTextFields["Passphrase or recovery key"]
        if !field.waitForExistence(timeout: 8) {
            app.staticTexts[name].firstMatch.tap()
            let restore = app.buttons["Restore “\(name)”"]
            XCTAssertTrue(restore.waitForExistence(timeout: 20))
            restore.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(key + "\n")
        sleep(20)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'open this library'")).firstMatch.exists, "Wrong key")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
}
