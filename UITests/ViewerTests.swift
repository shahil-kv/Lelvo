import XCTest

/// Test plan 4.4 (double-tap zoom), 4.8 (favorite from the viewer shows in the grid), 4.18 (place opens Maps) on the
/// demo library.
final class ViewerTests: XCTestCase {
    private var app: XCUIApplication!
    private var grid: XCUIElement { app.collectionViews["galleryGrid"] }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "600"]
        app.launch()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 30))
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func openPhoto() {
        let photo = grid.cells.matching(NSPredicate(format: "NOT (label BEGINSWITH 'Video')")).element(boundBy: 2)
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); photo.tap()
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 10), "Viewer open")
    }

    private func favoritesLabel() -> String {
        app.buttons["Collections"].firstMatch.tap()
        let fav = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Favorites'")).firstMatch
        // The row hides while there are no favorites, like Photos.
        let l = fav.waitForExistence(timeout: 5) ? fav.label : "Favorites, 0 items"
        app.buttons["Photos"].firstMatch.tap()
        return l
    }

    func test4_8_favoriteFromViewerShowsInGrid() {
        print("QA favorites before:", favoritesLabel())
        openPhoto()
        let add = app.buttons["Add to Favorites"].firstMatch
        let remove = app.buttons["Remove from Favorites"].firstMatch
        let wasFav = remove.exists
        (wasFav ? remove : add).tap()
        XCTAssertTrue((wasFav ? add : remove).waitForExistence(timeout: 5), "Heart switches")
        app.buttons["Close"].firstMatch.tap()
        app.buttons["Collections"].firstMatch.tap()
        let fav = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Favorites'")).firstMatch
        XCTAssertTrue(fav.waitForExistence(timeout: 10), "Favorites shows the new heart")
        print("QA favorites row:", fav.label)
        shot("favorites-after")
    }

    func test4_4_doubleTapZooms() {
        openPhoto()
        sleep(2)
        let before = app.screenshot().pngRepresentation
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        sleep(2)
        let after = app.screenshot().pngRepresentation
        shot("zoomed")
        XCTAssertNotEqual(before, after, "Double tap changes the picture (zoom)")
        // Zoomed in, a swipe pans instead of paging: the Info button stays on the same photo.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
    }

    func test4_18_placeOpensMaps() {
        // A photo with a place: open from the Map's first pin.
        app.buttons["Collections"].firstMatch.tap()
        let map = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Map'")).firstMatch
        for _ in 0..<8 where !map.isHittable { app.swipeUp() }
        map.tap(); sleep(3)
        let pin = app.buttons.matching(NSPredicate(format: "label MATCHES '.*[0-9].*'")).element(boundBy: 0)
        XCTAssertTrue(pin.waitForExistence(timeout: 10)); pin.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 10))
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 10)); app.buttons["Info"].tap()
        let open = app.buttons["Open in Maps"].firstMatch
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Open in Maps under Location")
        open.tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 15), "Maps opens")
        maps.terminate()
    }
}
