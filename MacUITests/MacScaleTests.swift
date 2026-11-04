import XCTest

/// The Mac app with 100,000 sample items: every step must answer, and the timings are printed for comparison.
final class MacScaleTests: XCTestCase {
    func testOneHundredThousandItems() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "100000", "-UITestDemoAlbums"]
        func timed(_ name: String, _ work: () -> Void) {
            let start = Date()
            work()
            print("MACSCALE \(name): \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        }
        let tiles = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Photo,", "Video,"))
        func row(_ title: String) -> XCUIElement {
            app.outlines.firstMatch.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title)).firstMatch
        }
        timed("launch to first photos") {
            app.launch()
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 240), "The library opens")
        }
        timed("5 scrolls") {
            for _ in 0..<5 { app.collectionViews.firstMatch.scroll(byDeltaX: 0, deltaY: -3000) }
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60))
        }
        timed("zoom out and in") {
            app.buttons["Remove"].firstMatch.click()
            app.buttons["Add"].firstMatch.click()
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60))
        }
        timed("Videos") {
            row("Videos").click()
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60))
        }
        timed("Select All") {
            row("Library").click()
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60))
            app.buttons["Select"].firstMatch.click()
            sleep(1)  // The bar slides in; a click during that misses it.
            let began = Date()
            app.buttons["Select All"].firstMatch.click()
            defer { print("MACSCALE Select All itself: \(String(format: "%.1f", Date().timeIntervalSince(began))) s") }
            XCTAssertTrue(app.buttons["Deselect All"].firstMatch.waitForExistence(timeout: 60))
            app.typeKey(.escape, modifierFlags: [])
        }
        timed("Search") {
            row("Search").click()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 60))
            field.click()
            field.typeText("novem")
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60), "Search finds items")
        }
        timed("Memories") {
            row("Memories").click()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "20")).firstMatch.waitForExistence(timeout: 60))
        }
        timed("Backup") {
            row("Backup").click()
            let duplicates = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", "Duplicates", "Duplicates")).firstMatch
            XCTAssertTrue(duplicates.waitForExistence(timeout: 60))
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }
}
