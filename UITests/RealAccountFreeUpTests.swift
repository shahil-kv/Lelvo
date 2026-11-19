import XCTest

/// Test plan Phase 8 on the signed-in "Lelvo QA" simulator (synthetic photos only). Skipped unless `QA_DIR` is set.
/// 8.1 check, 8.3 cancel iOS's delete prompt, 8.4 confirm it, 8.6 save everything back. Backup is forced off.
final class RealAccountFreeUpTests: XCTestCase {
    private var app: XCUIApplication!
    private let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func note(_ s: String) { print("QA freeup: \(s)"); let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a) }
    private func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }

    private func row(_ title: String) -> XCUIElement {
        let r = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        for _ in 0..<8 where !(r.exists && r.isHittable) { app.swipeUp() }
        return r
    }

    private func value(_ label: String) -> String {
        let e = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        return e.exists ? e.label : "?"
    }

    /// Answers iOS's own delete confirmation, wherever it shows.
    private func answerDelete(_ allow: Bool) -> Bool {
        let until = Date().addingTimeInterval(20)
        while Date() < until {
            for a in [app.alerts.firstMatch, spring.alerts.firstMatch] where a.exists {
                note("prompt buttons: \(a.buttons.allElementsBoundByIndex.map(\.label))")
                let b = a.buttons.allElementsBoundByIndex.first { allow ? $0.label == "Delete" || $0.label == "Allow" : $0.label == "Don’t Allow" || $0.label == "Cancel" }
                if let b { b.tap(); return true }
            }
            sleep(1)
        }
        return false
    }

    func testPhase8_freeUpAndSaveBack() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        app = XCUIApplication()
        app.launchArguments = ["-autoBackup", "NO", "-backupPaused", "YES"]
        app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        let tab = app.buttons["Backup"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30)); tab.tap()

        row("Free up space").tap()
        let check = app.buttons["Check what's safe to remove"]
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        check.tap()
        let stop = app.buttons["Stop"]
        sleep(3)
        let until = Date().addingTimeInterval(300)
        while stop.exists, Date() < until { sleep(3) }
        sleep(2)
        note("8.1 \(value("Backed up and on this")) | \(value("Checked, safe to remove")) | \(value("Space you can free"))")
        shot("8.1-checked")

        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5) && remove.isEnabled, "Something verified to remove")
        note("remove button: \(remove.label)")

        // 8.3: cancel the system prompt; nothing may change.
        remove.tap()
        note("8.3 cancel answered: \(answerDelete(false))")
        sleep(3); shot("8.3-after-cancel")
        note("8.3 after cancel: \(value("Checked, safe to remove"))")

        // 8.4: confirm.
        remove.tap()
        note("8.4 confirm answered: \(answerDelete(true))")
        sleep(8); shot("8.4-after-delete")
        note("8.4 after delete: \(value("Backed up and on this")) | \(value("Checked, safe to remove"))")

        // 8.6: everything is now cloud-only; save it all back.
        app.navigationBars.buttons.firstMatch.tap()
        row("Save all to Photos").tap()
        let save = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save ")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        note("8.6 \(save.label)")
        save.tap()
        if app.buttons["Save to Photos"].waitForExistence(timeout: 5) { app.buttons["Save to Photos"].tap() }
        _ = answerDelete(true) // a Photos add-only prompt, if any
        let done = Date().addingTimeInterval(600)
        while Date() < done {
            if app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'saved'")).firstMatch.exists { break }
            sleep(5)
        }
        shot("8.6-after-save")
        note("8.6 texts: \(app.staticTexts.allElementsBoundByIndex.prefix(15).map(\.label))")
    }

    /// After an interrupted save: Save all again offers only what is still cloud-only, and finishes.
    func testPhase8_saveRest() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        app = XCUIApplication()
        app.launchArguments = ["-autoBackup", "NO", "-backupPaused", "YES"]
        app.launch()
        let tab = app.buttons["Backup"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30)); tab.tap()
        row("Save all to Photos").tap()
        let save = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Save ")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        note("again: \(save.label)")
        save.tap()
        if app.buttons["Save to Photos"].waitForExistence(timeout: 5) { app.buttons["Save to Photos"].tap() }
        let left = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Only in the cloud'")).firstMatch
        let until = Date().addingTimeInterval(900)
        while Date() < until, left.exists, left.label != "Only in the cloud, 0" { sleep(10) }
        sleep(5); shot("8.6-done")
        note("end: \(app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label))")
    }
}
