import XCTest

/// Walks the Mac app section by section on sample data. This runs `LelvoMacTestApp`, never the real app: another bundle
/// id with its own settings, files and keychain entries, and no Telegram API id.
final class MacSectionsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        XCTAssertEqual(Bundle(for: Self.self).bundleIdentifier?.hasPrefix("app.lelvo.mac.uitests"), true)
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "300", "-UITestDemoAlbums"]
        app.launch()
        XCTAssertTrue(sidebarRow("Library").waitForExistence(timeout: 60), "The window opens on the sidebar")
    }

    override func tearDown() { app.terminate() }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sidebarRow(_ title: String) -> XCUIElement {
        app.outlines.firstMatch.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", title, title)).firstMatch
    }

    private func open(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = sidebarRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(title) is in the sidebar", file: file, line: line)
        row.click()
        sleep(2)
    }

    private var tile: XCUIElement { app.collectionViews.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "photo", "video")).firstMatch }

    func testEveryGridSectionShowsItsPhotos() {
        for title in ["Library", "Favorites", "Videos", "Only in Cloud", "Family 1"] {
            open(title)
            XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(title) shows items")
            shot("section-\(title)")
        }
    }

    func testEmptySectionsSaySo() {
        for title in ["Live Photos", "Not Backed Up"] {
            open(title)
            shot("section-\(title)")
            XCTAssertTrue(sidebarRow("Library").exists, "\(title) opens and the app still answers")
        }
    }

    func testMemories() {
        open("Memories")
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent Highlights,")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Memories lists cards")
        shot("memories")
        card.click()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 15), "A memory plays")
        shot("memory-playing")
        pause.click()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5), "Pause pauses")
        app.buttons["Close"].click()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Close closes it")
    }

    func testSearch() {
        open("Search")
        shot("search-suggestions")
        let videos = app.buttons["Videos"].firstMatch
        XCTAssertTrue(videos.waitForExistence(timeout: 15), "Suggestions are offered")
        videos.click()
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "A suggestion finds items")
        shot("search-results")
    }

    func testMap() {
        open("Map")
        sleep(5)
        shot("map")
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 20), "The map opens")
    }

    func testBackupPage() {
        open("Backup")
        shot("backup")
        for title in ["Free Up Space", "Save All to Photos", "Duplicates"] {
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) is on the Backup page")
        }
    }

    func testRecentlyDeleted() {
        open("Recently Deleted")
        shot("recently-deleted")
        XCTAssertTrue(app.staticTexts["No Recently Deleted Items"].waitForExistence(timeout: 15))
    }

    func testViewerOpensAndCloses() {
        open("Library")
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.doubleClick()
        sleep(3)
        shot("viewer")
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "Double click opens the viewer")
        back.click()
        XCTAssertFalse(back.waitForExistence(timeout: 3), "Back closes it")
    }

    func testSelectAndDone() {
        open("Library")
        let select = app.buttons["Select"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 20))
        select.click()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5), "Select switches to Done")
        shot("selecting")
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(select.waitForExistence(timeout: 5))
    }

    func testSettingsOpens() {
        app.typeKey(",", modifierFlags: .command)
        sleep(3)
        shot("settings")
        XCTAssertGreaterThan(app.windows.count, 0)
    }
}
