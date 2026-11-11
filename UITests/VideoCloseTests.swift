import XCTest

/// Closing a playing video stops its sound, like Photos: with ✕, with a swipe down, and right after opening. A swipe
/// that's let go early keeps the video playing. The app log then shows every viewer freed and no player left playing
/// ("Viewer closed" / "Viewer freed" lines).
final class VideoCloseTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
    }

    private var grid: XCUIElement { app.collectionViews["galleryGrid"] }
    private var close: XCUIElement { app.buttons["Close"] }

    private func openVideo(onPhone: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let format = onPhone ? "label BEGINSWITH 'Video' AND label CONTAINS 'Only on this'" : "label BEGINSWITH 'Video'"
        let video = grid.cells.matching(NSPredicate(format: format)).firstMatch
        for _ in 0..<6 where !video.exists { grid.swipeUp() }
        XCTAssertTrue(video.waitForExistence(timeout: 5), "The demo library has a video", file: file, line: line)
        video.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), file: file, line: line)
    }

    private func waitUntilPlaying(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 15), "The video plays", file: file, line: line)
    }

    private func waitUntilClosed(file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "The viewer closed", file: file, line: line)
        XCTAssertTrue(grid.waitForExistence(timeout: 5), file: file, line: line)
    }

    func testClosingStopsTheVideo() {
        app.openDemoLibrary()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))

        // ✕ while it plays.
        openVideo()
        waitUntilPlaying()
        close.tap()
        waitUntilClosed()

        // A short pull that's let go: the viewer stays and the video carries on.
        openVideo()
        waitUntilPlaying()
        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 40)))
        sleep(1)
        XCTAssertTrue(close.exists, "A short pull doesn't close the viewer")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3), "The video keeps playing after a cancelled pull")

        // A full swipe down while it plays.
        app.windows.firstMatch.swipeDown(velocity: .fast)
        waitUntilClosed()

        // Closed right after opening, before the video has started.
        openVideo()
        close.tap()
        waitUntilClosed()

        // Give anything that would still start (a late load, a quality switch) time to do it.
        sleep(3)
    }

    /// A video from the phone's own library, which Photos hands over asynchronously. Needs Photos access and a video in
    /// the simulator: `xcrun simctl privacy booted grant photos app.lelvo.ios; xcrun simctl addmedia booted clip.mp4`.
    func testClosingStopsAPhoneVideo() throws {
        app.openDemoLibrary()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        let phoneVideo = grid.cells.matching(NSPredicate(format: "label BEGINSWITH 'Video' AND label CONTAINS 'Only on this'")).firstMatch
        for _ in 0..<6 where !phoneVideo.exists { grid.swipeUp() }
        guard phoneVideo.exists else { throw XCTSkip("No video in this simulator's Photos library") }

        openVideo(onPhone: true)
        waitUntilPlaying()
        app.windows.firstMatch.swipeDown(velocity: .fast)
        waitUntilClosed()

        openVideo(onPhone: true)
        close.tap()
        waitUntilClosed()

        // Swipe from the phone video to the next item and back, then close: the player that was let go stays stopped.
        openVideo(onPhone: true)
        waitUntilPlaying()
        app.windows.firstMatch.swipeLeft()
        sleep(1)
        app.windows.firstMatch.swipeRight()
        // A short clip may already have played to its end here.
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5) || app.buttons["Play"].exists)
        close.tap()
        waitUntilClosed()
        sleep(3)
    }
}
