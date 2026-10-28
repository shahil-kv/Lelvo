import XCTest

/// Walks the Collections, Search and Duplicates screens on the demo library like a person would: Memories (play,
/// hold, swipe down to close), the map, album and media type sections, search suggestions and results, and Settings.
/// Each step must stay responsive (the map once froze the app). Screenshots go to the test results, and to
/// `CG_SCREENSHOT_DIR` when set.
final class CollectionsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestDemoLibrary", "-UITestDemoCount", "600"]
        app.launch()
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 30))
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["CG_SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func settle(_ seconds: TimeInterval = 1.5) { Thread.sleep(forTimeInterval: seconds) }

    /// Tapping the current tab again goes back to its first screen (iOS 26 moves the back button out of the bar).
    private func backToCollections() { app.buttons["Collections"].firstMatch.tap() }

    func testCollectionsMapAndMemories() {
        app.buttons["Collections"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 20))
        settle(3)
        shot("collections-top")

        // Memories: play one, hold to pause, swipe down to close.
        let memory = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ago,")).firstMatch
        if memory.waitForExistence(timeout: 10) {
            memory.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
            settle(2)
            shot("memory-playing")
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 10), "Swiping down closes the memory")
        }

        // The map: open, zoom, and it must still answer.
        let map = app.buttons["Map"].firstMatch
        for _ in 0..<4 where !map.isHittable { app.swipeUp() }
        map.tap()
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 20))
        settle(4)
        shot("map")
        app.maps.firstMatch.pinch(withScale: 2.5, velocity: 2)
        settle(2)
        shot("map-zoomed")
        let cluster = app.otherElements.matching(NSPredicate(format: "label CONTAINS %@", "photo")).firstMatch
        if cluster.exists, cluster.isHittable {
            cluster.tap()
            settle(2)
            shot("map-cluster-photos")
        }
        backToCollections()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 10), "The map stays responsive")

        for _ in 0..<3 { app.swipeUp() }
        settle()
        shot("collections-bottom")
        let more = app.buttons["Show More"].firstMatch
        if more.exists && more.isHittable {
            more.tap()
            settle()
            shot("collections-media-more")
        }

        // Memories → See All.
        for _ in 0..<6 { app.swipeDown() }
        let seeAll = app.buttons["See All"].firstMatch
        if seeAll.waitForExistence(timeout: 5) {
            seeAll.tap()
            XCTAssertTrue(app.navigationBars["Memories"].waitForExistence(timeout: 10))
            settle(2)
            shot("memories-all")
            backToCollections()
        }
    }

    func testSearchAndSettings() {
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 20))
        settle(3)
        shot("search-suggestions")

        // Settings opens from the gear on every tab, here from Search.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        shot("settings")
        app.buttons["Done"].tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("video")
        settle(2)
        shot("search-results")
        XCTAssertTrue(app.collectionViews["galleryGrid"].cells.firstMatch.waitForExistence(timeout: 10), "Searching for videos finds the demo's videos")
    }

    func testDuplicatesAndSimilar() {
        app.buttons["Collections"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: 20))
        let duplicates = app.buttons["Duplicates and Similar"].firstMatch
        for _ in 0..<8 where !duplicates.isHittable { app.swipeUp() }
        duplicates.tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 10))
        settle(4)
        shot("duplicates")
    }
}
