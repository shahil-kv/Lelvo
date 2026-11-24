import XCTest

/// Test plan 1.4 + OPEN_ISSUES I6/I7 on the signed-in "Lelvo QA" simulator: Settings → Library → New library.
/// Takes the I6 screenshot with the keyboard up, creates "Lelvo QA Test" (passphrase from `QA_DIR`/new-pass.txt, key
/// written to `QA_DIR`/new-key.txt), then switches back to "Lelvo QA" (passphrase on line 2 of qa-library.txt).
/// Automatic backup is forced off so nothing uploads into the new library. Never deletes any channel.
final class RealAccountSettingsLibraryTests: XCTestCase {
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func openLibrarySettings(_ app: XCUIApplication) {
        let gear = app.buttons.matching(NSPredicate(format: "label == 'Settings' OR identifier == 'Settings'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 30)); gear.tap()
        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Library'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
    }

    private func type(_ app: XCUIApplication, into field: XCUIElement, _ text: String) {
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        app.typeText(text)
    }

    func testCreateAndSwitchBack() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["QA_DIR"],
              let newPass = try? String(contentsOfFile: dir + "/new-pass.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let qaFile = try? String(contentsOfFile: dir + "/qa-library.txt", encoding: .utf8) else { throw XCTSkip("QA only") }
        let qaPass = qaFile.split(separator: "\n").first { $0.hasPrefix("Passphrase:") }
            .map { $0.dropFirst("Passphrase:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        let app = XCUIApplication()
        app.launchArguments = ["-autoBackup", "NO", "-backupPaused", "YES", "-QAPlainFields"]
        app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        openLibrarySettings(app)

        let new = app.buttons["New library"]
        XCTAssertTrue(new.waitForExistence(timeout: 20)); new.tap()
        let name = app.textFields["Library name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "Lelvo QA Test")
        // Show both passphrases first: a plain text field takes typed text reliably under UI test (I7).
        for _ in 0..<2 { let show = app.buttons["Show"].firstMatch; if show.exists { show.tap() } }
        type(app, into: app.textFields["Passphrase (10+ characters)"], newPass)
        shot("I6-keyboard-up")   // the button must not cover the warning card
        type(app, into: app.textFields["Repeat passphrase"], newPass)
        let ack = app.buttons["I understand. I'll keep both safe."]
        while !ack.isHittable { app.swipeUp() }
        ack.tap()
        print("QA fields:", app.textFields.allElementsBoundByIndex.map { ($0.label, ($0.value as? String)?.count ?? -1) })
        shot("I6-filled")
        app.buttons["Create and switch"].tap()

        let key = app.descendants(matching: .any)["Recovery key"].firstMatch
        XCTAssertTrue(app.buttons["I've saved it"].waitForExistence(timeout: 90), "The recovery key should be shown once")
        if let v = key.value as? String, !v.isEmpty { try v.write(toFile: dir + "/new-key.txt", atomically: true, encoding: .utf8) }
        shot("recovery-key-shown")
        app.buttons["I've saved it"].tap()
        sleep(5)

        // Back to the QA library so the other tests keep working.
        let qa = app.staticTexts["Lelvo QA"].firstMatch
        XCTAssertTrue(qa.waitForExistence(timeout: 30)); qa.tap()
        let pass = app.secureTextFields["Passphrase"]
        XCTAssertTrue(pass.waitForExistence(timeout: 10))
        type(app, into: pass, qaPass)
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Switch to'")).firstMatch.tap()
        sleep(15)
        shot("switched-back")
    }
}
