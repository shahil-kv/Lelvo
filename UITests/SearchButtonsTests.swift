import XCTest

/// Section 3 of the button check: every suggestion and button in Search answers. Sample library only, so matching on
/// what's inside real photos is checked by hand on a device.
final class SearchButtonsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "2000", "-UITestDemoAlbums"]
        app.launch()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 40))
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 20))
    }

    private var grid: XCUIElement { app.collectionViews["galleryGrid"] }
    private var field: XCUIElement { app.searchFields.firstMatch }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func button(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// Clears the field and closes the keyboard, back to the suggestions.
    private func leaveSearch() {
        field.buttons["Clear text"].tap()
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 3) { close.tap() }
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    func testTrySuggestionsSearch() {
        for kind in ["Videos", "Favorites"] {
            let row = button(kind)
            reveal(row)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(kind) is suggested")
            row.tap()
            XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "\(kind) finds items")
            screenshot("try-\(kind)")
            leaveSearch()
            XCTAssertFalse(grid.waitForExistence(timeout: 2), "Clearing returns to the suggestions")
        }
    }

    func testScreenshotsSuggestionAnswers() {
        let row = button("Screenshots")
        reveal(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 10) || grid.waitForExistence(timeout: 5),
                      "It shows results or says there are none")
    }

    func testTypingFindsAndOpensAResult() {
        field.tap()
        field.typeText("video")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "Typing searches")
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "A result opens in the viewer")
        app.buttons["Close"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
    }

    func testNoResultsSaysSo() {
        field.tap()
        field.typeText("qqqzzz")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 10))
        screenshot("no-results")
    }

    func testRecentSearchIsRememberedAndCleared() {
        field.tap()
        field.typeText("video\n")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        leaveSearch()
        let recent = button("video")
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "The search is remembered")
        screenshot("recent")
        recent.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "A recent search runs again")
        leaveSearch()
        let clear = button("Clear")
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.tap()
        XCTAssertFalse(recent.waitForExistence(timeout: 2), "Clear forgets recent searches")
    }

    func testShowMoreAndLessOnMonths() {
        let more = button("Show More")
        reveal(more)
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Long sections offer Show More")
        more.tap()
        let less = button("Show Less")
        reveal(less)
        XCTAssertTrue(less.waitForExistence(timeout: 5), "Show More opens the rest")
        screenshot("show-more")
        less.tap()
        XCTAssertTrue(button("Show More").waitForExistence(timeout: 5), "Show Less closes it")
    }

    func testAMonthSuggestionSearches() {
        let month = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "2026")).firstMatch
        reveal(month)
        XCTAssertTrue(month.waitForExistence(timeout: 10), "Months are suggested")
        month.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "A month finds its photos")
    }

    func testAPlaceSuggestionAnswers() {
        let place = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Kochi")).firstMatch
        if !place.waitForExistence(timeout: 5) {
            XCTFail("No sample place was suggested. Places need the system's place names, so check this on a device.")
            return
        }
        place.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
    }
}
