import XCTest

/// Section 1 of the button check: every button in the viewer and the selection bar answers a tap.
/// Runs on the App Review demo library, so it can't reach a real Telegram download. The banner's Cancel button is not
/// covered here, because demo files arrive at once and it has nothing to cancel (`SharedWorkTests` covers the logic).
final class PhotosButtonsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset"]
        app.launch()
    }

    private var grid: XCUIElement { app.collectionViews["galleryGrid"] }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The reviewer sign-in from `DemoModeTests`.
    private func openDemoLibrary() {
        app.passIntro()
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 15))
        let dial = app.textFields["Country code"]
        dial.tap()
        dial.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "1")
        phone.tap()
        phone.typeText("5550100199")
        app.buttons["Continue"].tap()
        let code = app.textFields["Login code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.typeText("24680")
        let allow = app.buttons["Allow Access"]
        let begin = app.buttons["Start using Lelvo"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10) || begin.exists)
        if allow.exists {
            allow.tap()
            let dontAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
            if dontAllow.waitForExistence(timeout: 5) { dontAllow.tap() }
        }
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        begin.tap()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "The demo library opens")
    }

    /// Closes the share sheet, whichever close control this iOS version gives it.
    private func closeShareSheet() {
        let close = app.navigationBars["UIActivityContentView"].buttons.firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown(velocity: .fast) }
    }

    /// The system share sheet is up.
    private var shareSheet: XCUIElement { app.otherElements["ActivityListView"] }

    func testViewerInfo() {
        openDemoLibrary()
        grid.cells.element(boundBy: 1).tap()
        let info = app.buttons["Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()
        XCTAssertTrue(app.navigationBars["Info"].waitForExistence(timeout: 5), "Info opens its sheet")
        screenshot("viewer-info")
    }

    func testViewerShare() {
        openDemoLibrary()
        grid.cells.element(boundBy: 1).tap()
        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15), "Share opens the share sheet")
        screenshot("viewer-share")
    }

    func testViewerShareOriginal() {
        openDemoLibrary()
        grid.cells.element(boundBy: 1).tap()
        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.press(forDuration: 1.2)
        let original = app.buttons["Share Original"]
        XCTAssertTrue(original.waitForExistence(timeout: 5), "Touch and hold offers the original")
        original.tap()
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15), "Share Original opens the share sheet")
    }

    func testViewerDeleteCancelKeepsTheItem() {
        openDemoLibrary()
        let before = grid.cells.count
        grid.cells.element(boundBy: 1).tap()
        let delete = app.buttons["Delete from cloud"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        let cancel = app.alerts.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Delete asks first")
        cancel.tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1), "Cancel closes the question")
        app.buttons["Close"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        XCTAssertEqual(grid.cells.count, before, "Cancel deletes nothing")
    }

    /// The simulator has no Photos access here, so the answer is "Couldn't save". What matters is that the tap answers.
    func testViewerSaveAnswers() {
        openDemoLibrary()
        grid.cells.element(boundBy: 1).tap()
        let save = app.buttons["Save to Photos"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 15), "Save says how it went")
        screenshot("viewer-save-answer")
    }

    func testGridSizeMenu() {
        openDemoLibrary()
        let menu = app.buttons["Grid size"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let legend = app.buttons["What the icons mean"]
        XCTAssertTrue(legend.waitForExistence(timeout: 5), "The menu opens")
        screenshot("grid-size-menu")
        legend.tap()
        XCTAssertFalse(legend.waitForExistence(timeout: 1), "The menu closes")
        screenshot("icon-legend")
    }

    func testSelectionBarShare() {
        openDemoLibrary()
        app.buttons["Select"].tap()
        grid.cells.element(boundBy: 1).tap()
        grid.cells.element(boundBy: 2).tap()
        screenshot("selection-bar")
        app.buttons["Share"].tap()
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 20), "Share opens the share sheet for the selection")
    }

    func testSelectionBarSaveAnswers() {
        openDemoLibrary()
        app.buttons["Select"].tap()
        grid.cells.element(boundBy: 1).tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 20), "Save says how it went")
        screenshot("selection-save-answer")
    }

    func testSelectionBarDeleteCancelKeepsTheItems() {
        openDemoLibrary()
        let before = grid.cells.count
        app.buttons["Select"].tap()
        grid.cells.element(boundBy: 1).tap()
        app.buttons["Delete from cloud"].tap()
        let cancel = app.alerts.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Delete asks first")
        cancel.tap()
        XCTAssertEqual(grid.cells.count, before, "Cancel deletes nothing")
    }

    func testChoosingColumnsChangesTheGrid() {
        openDemoLibrary()
        let before = grid.cells.count
        app.buttons["Grid size"].tap()
        let six = app.buttons["6 columns"]
        XCTAssertTrue(six.waitForExistence(timeout: 5), "The menu lists column sizes")
        six.tap()
        let more = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", before), object: grid.cells)
        wait(for: [more], timeout: 10)
        screenshot("six-columns")
    }

    func testIconLegendDoneCloses() {
        openDemoLibrary()
        app.buttons["Grid size"].tap()
        app.buttons["What the icons mean"].tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertFalse(done.waitForExistence(timeout: 2), "Done closes the sheet")
    }

    func testTapHidesAndShowsTheViewerButtons() {
        openDemoLibrary()
        grid.cells.element(boundBy: 1).tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        wait(for: [hidden], timeout: 5)
        middle.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "A second tap brings them back")
    }

    func testVideoControls() {
        openDemoLibrary()
        let video = grid.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Video")).firstMatch
        for _ in 0..<6 where !video.exists { grid.swipeUp() }
        XCTAssertTrue(video.waitForExistence(timeout: 5), "The demo library has a video")
        video.tap()

        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20), "The video plays by itself")
        pause.tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Pause pauses")
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "Play plays")

        let mute = app.buttons["Mute"].exists ? app.buttons["Mute"] : app.buttons["Unmute"]
        let other = mute.label == "Mute" ? "Unmute" : "Mute"
        mute.tap()
        XCTAssertTrue(app.buttons[other].waitForExistence(timeout: 5), "The speaker button switches")

        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.6)
        screenshot("video-seek")

        app.buttons["More options"].tap()
        let speed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Playback Speed")).firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 5), "More options opens")
        XCTAssertTrue(app.buttons["AirPlay"].exists, "More options offers AirPlay")
        speed.tap()
        let fast = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "1.5")).firstMatch
        XCTAssertTrue(fast.waitForExistence(timeout: 5), "Playback Speed lists speeds")
        fast.tap()
        app.buttons["More options"].tap()
        let changed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playback Speed · 1.5")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 5), "The speed changed")
        screenshot("video-speed")
    }

    func testViewerShowsAnswerAndBlocksSecondShare() {
        openDemoLibrary()
        grid.cells.element(boundBy: 1).tap()
        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        // Demo files are quick, so all this can check is that one tap ends in exactly one share sheet.
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15))
        XCTAssertEqual(app.otherElements.matching(identifier: "ActivityListView").count, 1)
    }

    func testSelectionBarDeleteFromBackupConfirms() {
        openDemoLibrary()
        let before = grid.cells.count
        app.buttons["Select"].tap()
        grid.cells.element(boundBy: 1).tap()
        app.buttons["Delete from cloud"].tap()
        let confirm = app.alerts.buttons["Delete from Backup"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete asks first")
        confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", before - 1), object: grid.cells)
        wait(for: [gone], timeout: 15)
    }

    /// The demo library is all cloud items, so the phone-only actions have nothing to act on.
    func testSelectionBarDisablesWhatDoesNotApply() {
        openDemoLibrary()
        app.buttons["Select"].tap()
        grid.cells.element(boundBy: 1).tap()
        XCTAssertFalse(app.buttons["Delete from iPhone"].isEnabled, "Nothing here is on the iPhone")
        XCTAssertFalse(app.buttons["Back up 0 to the cloud"].isEnabled, "Nothing here needs backing up")
    }
}
