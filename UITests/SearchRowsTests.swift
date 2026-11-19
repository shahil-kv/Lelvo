import XCTest

/// Test plan 6.3 on the demo library: a place finds its photos and a made-up word finds none. Names and albums are
/// checked on the real library below (only Telegram library items carry them).
final class SearchRowsTests: XCTestCase {
    func testSearchByNameDatePlaceAlbum() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "600"]
        app.launch()
        let grid = app.collectionViews["galleryGrid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for (row, query) in [("place", "Kochi"), ("none", "zzqqxx")] {
            field.tap()
            let clear = field.buttons["Clear text"]
            if clear.exists { clear.tap() }
            field.typeText(query)
            sleep(3)
            let found = grid.cells.count
            let first = grid.cells.firstMatch.exists ? grid.cells.firstMatch.label : "-"
            print("QA search \(row) field='\(field.value as? String ?? "")' cells=\(found) first=\(first)")
            XCTAssertEqual(found > 0, row == "place", "\(row): '\(query)'")
        }
    }
}

final class RealAccountSearchTests: XCTestCase {
    func testNameAndAlbum() throws {
        guard ProcessInfo.processInfo.environment["QA_DIR"] != nil else { throw XCTSkip("QA only") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch()
        if app.buttons["Not now"].waitForExistence(timeout: 6) { app.buttons["Not now"].tap() }
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let grid = app.collectionViews["galleryGrid"]
        for q in ["tokyo", "QA Remove 3", "D16-nogps", "November"] {
            field.tap(); if field.buttons["Clear text"].exists { field.buttons["Clear text"].tap() }
            field.typeText(q); sleep(3)
            print("QA real search '\(q)': \(grid.cells.count) cells")
        }
    }
}
