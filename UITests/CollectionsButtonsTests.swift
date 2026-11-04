import XCTest

/// Section 2 of the button check: every row and button in Collections opens what it says. Each one has its own test,
/// so one failure can't hide the others. Runs on the sample library, so rows that need real Photos albums, Live Photos
/// or duplicates are checked by hand on a device.
final class CollectionsButtonsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "300", "-UITestDemoAlbums"]
        app.launch()
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 30))
        app.buttons["Collections"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 20))
    }

    private var grid: XCUIElement { app.collectionViews["galleryGrid"] }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(title),")).firstMatch
    }

    /// Scrolls until the element can be tapped, down the page or back up.
    private func reveal(_ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["Collections"].exists || element.exists, file: file, line: line)
        for _ in 0..<10 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<10 where !(element.exists && element.isHittable) { app.swipeDown() }
        XCTAssertTrue(element.exists && element.isHittable, "\(name) should be on the Collections screen", file: file, line: line)
    }

    private func open(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = row(title)
        reveal(element, title, file: file, line: line)
        element.tap()
    }

    private var memoryCard: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent Highlights,")).firstMatch }

    /// See All sits beside each section's title, so it's found by the order of the sections.
    private func seeAll(_ index: Int) -> XCUIElement { app.buttons.matching(identifier: "See All").element(boundBy: index) }

    // MARK: Memories

    func testMemoryPlaysAndItsButtonsAnswer() {
        XCTAssertTrue(memoryCard.waitForExistence(timeout: 15), "The sample library has memories")
        memoryCard.tap()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "A memory plays")
        pause.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5), "Pause pauses")
        screenshot("memory-paused")
        XCTAssertTrue(app.buttons["Next photo"].exists || app.otherElements["Next photo"].exists, "Tap areas exist")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        app.buttons["Play"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Play plays")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 10), "Close closes the memory")
    }

    func testMemoryShowAll() {
        XCTAssertTrue(memoryCard.waitForExistence(timeout: 15))
        memoryCard.tap()
        let showAll = app.buttons["Show All"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 10))
        showAll.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "Show All opens the memory's photos")
        screenshot("memory-show-all")
    }

    func testMemoriesSeeAllAndShowAllPhotos() {
        XCTAssertTrue(memoryCard.waitForExistence(timeout: 15))
        seeAll(0).tap()
        XCTAssertTrue(app.navigationBars["Memories"].waitForExistence(timeout: 10), "See All lists memories")
        let card = memoryCard
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.press(forDuration: 1.2)
        let showAll = app.buttons["Show All Photos"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 5), "Touch and hold offers Show All Photos")
        showAll.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
    }

    // MARK: Recent Days

    func testRecentDayOpens() {
        let day = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", " items")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 15))
        day.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "A day opens its photos")
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 5), "Its grid can select")
    }

    func testRecentDaysSeeAll() {
        XCTAssertTrue(memoryCard.waitForExistence(timeout: 15))
        seeAll(1).tap()
        XCTAssertTrue(app.navigationBars["Recent Days"].waitForExistence(timeout: 10), "See All lists the days")
        screenshot("recent-days")
        app.cells.firstMatch.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "A listed day opens")
    }

    // MARK: Albums

    func testFavoritesOpens() {
        open("Favorites")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        screenshot("favorites")
    }

    func testAlbumOpens() {
        open("Family 1")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
    }

    func testAlbumsSeeAll() {
        let all = app.buttons.matching(identifier: "See All").element(boundBy: 2)
        reveal(all, "Albums See All")
        all.tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 10), "See All lists every album")
        XCTAssertTrue(row("Family 5").waitForExistence(timeout: 5), "Albums past the first four are listed")
        screenshot("albums-all")
        row("Family 5").tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "A listed album opens")
    }

    // MARK: Places

    func testMapOpensAndAPinOpensItsPhotos() {
        open("Map")
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 20))
        sleep(4)
        screenshot("map")
        let pin = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "photo", "item")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 10), "The map shows pins")
        pin.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "A pin opens its photos")
        screenshot("map-pin-photos")
    }

    // MARK: Media Types

    func testVideosOpens() {
        open("Videos")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
    }

    func testOnlyInTheCloudOpens() {
        open("Only in the cloud")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
    }

    // MARK: Utilities

    func testDuplicatesOpens() {
        open("Duplicates and Similar")
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 10))
        sleep(5)
        screenshot("duplicates")
    }

    func testRecentlyDeletedEmpty() {
        open("Recently Deleted")
        XCTAssertTrue(app.staticTexts["No Recently Deleted Items"].waitForExistence(timeout: 10))
    }

    // MARK: Top bar

    func testSettingsOpensFromCollections() {
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 10))
    }

    func testTabTapReturnsToTheFirstScreen() {
        open("Videos")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        app.buttons["Collections"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 10))
    }
}
