import XCTest

/// Test plan Phase P on a simulator seeded with 40k photos (Scripts/seed-library.py) and signed in to a test library.
/// Skipped unless `QA_DIR` is set. Always launches with automatic backup forced off, so nothing is uploaded.
final class RealAccountScaleTests: XCTestCase {
    private let safe = ["-autoBackup", "NO", "-backupPaused", "YES"]

    private func note(_ s: String) {
        print("QA scale: \(s)")
        let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a)
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testP_fortyThousand() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication()
        app.launchArguments = safe
        var t = Date()
        app.launch()

        // Last setup screen after a fresh sign-in: turn automatic backup off before starting (belt and braces).
        let start = app.buttons["Start using Lelvo"]
        if start.waitForExistence(timeout: 15) {
            let toggle = app.switches.firstMatch
            if toggle.exists, (toggle.value as? String) == "1" { toggle.tap() }
            t = Date()
            start.tap()
        }
        if app.buttons["Not now"].waitForExistence(timeout: 5) { app.buttons["Not now"].tap() }
        let cell = app.collectionViews["galleryGrid"]
        XCTAssertTrue(cell.waitForExistence(timeout: 180), "Grid should show")
        note(String(format: "first grid %.1f s", Date().timeIntervalSince(t)))
        sleep(20) // let the first full photo scan settle
        shot("grid-first")

        // P.1 cold launch, three times.
        for i in 1...3 {
            app.terminate()
            t = Date()
            app.launch()
            XCTAssertTrue(app.collectionViews["galleryGrid"].waitForExistence(timeout: 60))
            note(String(format: "cold launch %d: %.1f s", i, Date().timeIntervalSince(t)))
            sleep(5)
        }

        // P.2 fast scroll through years and back.
        t = Date()
        for _ in 0..<40 { app.swipeUp(velocity: .fast) }
        note(String(format: "40 fast swipes down: %.1f s", Date().timeIntervalSince(t)))
        shot("grid-deep")
        t = Date()
        for _ in 0..<40 { app.swipeDown(velocity: .fast) }
        note(String(format: "40 fast swipes up: %.1f s", Date().timeIntervalSince(t)))

        // C.1 counts on the Backup tab.
        let tab = app.buttons["Backup"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap(); sleep(5); shot("backup-tab") }
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label).filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }
        note("backup tab: " + texts.joined(separator: " | "))
    }

    /// A11: hitch ratio while flinging the 40k grid (Apple's scroll metric; under 5 ms/s is smooth).
    func testP_scrollHitches() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication()
        app.launchArguments = safe
        app.launch()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        sleep(10)
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            grid.swipeUp(velocity: .fast)
            stopMeasuring()
            grid.swipeDown(velocity: .fast)
        }
    }
}
