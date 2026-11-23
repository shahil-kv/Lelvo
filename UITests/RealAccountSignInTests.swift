import XCTest

/// Signs the QA simulator into a real Telegram account, by hand-off: the number comes from `QA_DIAL` / `QA_PHONE`, the
/// login code and the two-step password from files the tester writes while the test waits (`QA_DIR`/otp.txt,
/// `QA_DIR`/2fa.txt). Skipped unless `QA_PHONE` is set, so it never runs in the normal suite. Nothing is logged.
final class RealAccountSignInTests: XCTestCase {
    func testSignInWithRealAccount() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["QA_DIR"] else { throw XCTSkip("QA_DIR not set") }
        // The number may also come from QA_DIR/phone.txt, deleted once read, so it never sits in a script or the chat.
        let phoneFile = dir + "/phone.txt"
        let phone = env["QA_PHONE"] ?? (try? waitForFile(phoneFile, seconds: 600))
        try? FileManager.default.removeItem(atPath: phoneFile)
        guard let phone, !phone.isEmpty else { throw XCTSkip("QA_PHONE not set") }
        let app = XCUIApplication()
        // QA_ARGS: extra launch arguments, e.g. "-autoBackup NO" so a seeded 40k simulator never starts uploading.
        app.launchArguments = ["-UITestReset"] + (env["QA_ARGS"]?.split(separator: " ").map(String.init) ?? [])
        app.launch()
        app.passIntro()
        let field = app.textFields["Phone number"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let dial = app.textFields["Country code"]
        dial.tap()
        dial.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + (env["QA_DIAL"] ?? "91"))
        field.tap()
        field.typeText(phone)
        app.buttons["Continue"].tap()

        let code = app.textFields["Login code"]
        XCTAssertTrue(code.waitForExistence(timeout: 60), "Telegram should ask for the code")
        let otp = try waitForFile(dir + "/otp.txt", seconds: 600)
        code.tap(); code.typeText(otp)

        // Two-step verification, when the account has it.
        let password = app.secureTextFields.firstMatch
        if password.waitForExistence(timeout: 15) {
            let pw = try waitForFile(dir + "/2fa.txt", seconds: 600)
            password.tap()
            password.typeText(pw + "\n")
        }
        try? FileManager.default.removeItem(atPath: dir + "/otp.txt")
        try? FileManager.default.removeItem(atPath: dir + "/2fa.txt")
        let after = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'library' OR label CONTAINS[c] 'passphrase' OR label CONTAINS[c] 'recovery'")).firstMatch
        XCTAssertTrue(after.waitForExistence(timeout: 90), "Sign-in should reach the library step")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }

    private func waitForFile(_ path: String, seconds: TimeInterval) throws -> String {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let s = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            sleep(1)
        }
        throw XCTSkip("Nothing in \(path) after \(Int(seconds)) s")
    }
}
