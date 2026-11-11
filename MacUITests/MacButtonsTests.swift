import XCTest

/// Clicks the Mac app's buttons on sample data, in `LelvoMacTestApp` (see `MacSectionsTests`). Anything that would change
/// the Photos library (Save to Photos, Delete from This Mac) is left out, and Sign Out only goes as far as Cancel.
final class MacButtonsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
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
        sleep(1)
    }

    private var tiles: XCUIElementQuery {
        app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Photo,", "Video,"))
    }

    private func labelled(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@ OR title == %@", text, text, text)).firstMatch
    }

    private func containing(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)).firstMatch
    }

    private func startSelecting() {
        open("Library")
        let select = app.buttons["Select"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 20))
        select.click()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5))
    }

    func testTilesFillTheWidthEvenly() {
        open("Library")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        let first = tiles.element(boundBy: 0).frame, second = tiles.element(boundBy: 1).frame
        XCTAssertEqual(first.minY, second.minY, accuracy: 1, "The first two tiles share a row")
        XCTAssertLessThanOrEqual(second.minX - first.maxX, 6, "Tiles sit next to each other, with no wide gaps")
        shot("grid-even")
    }

    func testZoomButtons() {
        open("Library")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        let before = tiles.firstMatch.frame.width
        for _ in 0..<3 { app.buttons["Add"].firstMatch.click() }
        sleep(1)
        let larger = tiles.firstMatch.frame.width
        XCTAssertGreaterThan(larger, before, "+ makes tiles bigger")
        for _ in 0..<6 { app.buttons["Remove"].firstMatch.click() }
        sleep(1)
        XCTAssertLessThan(tiles.firstMatch.frame.width, larger, "− makes tiles smaller")
    }

    func testSelectionBar() {
        startSelecting()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        tiles.element(boundBy: 0).click()
        tiles.element(boundBy: 1).click()
        XCTAssertTrue(containing("2 selected").waitForExistence(timeout: 5), "Clicks select")
        shot("two-selected")
        app.buttons["Select All"].firstMatch.click()
        XCTAssertTrue(app.buttons["Deselect All"].firstMatch.waitForExistence(timeout: 10), "Select All selects all")
        app.buttons["Deselect All"].firstMatch.click()
        XCTAssertTrue(app.buttons["Select All"].firstMatch.waitForExistence(timeout: 10), "Deselect All clears")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["Select"].firstMatch.waitForExistence(timeout: 5), "Esc ends selecting")
    }

    func testShareAnswersAtOnce() {
        startSelecting()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        tiles.element(boundBy: 0).click()
        app.buttons.matching(identifier: "Share").allElementsBoundByIndex.last(where: \.isEnabled)?.click()
        let preparing = containing("Preparing"), failed = containing("couldn't be downloaded")
        let answered = NSPredicate { _, _ in preparing.exists || failed.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: answered, object: nil)], timeout: 3)
        shot("share-answer")
    }

    func testExportOpensTheFolderPicker() {
        startSelecting()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        tiles.element(boundBy: 0).click()
        labelled("Export").click()
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        let panelCancel = app.dialogs.buttons["Cancel"].firstMatch
        let shown = NSPredicate { _, _ in cancel.exists || panelCancel.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 10)
        shot("export-panel")
        (cancel.exists ? cancel : panelCancel).click()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5), "Cancel returns to the grid")
    }

    func testDeleteFromBackup() {
        startSelecting()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        tiles.element(boundBy: 0).click()
        XCTAssertTrue(containing("1 selected").waitForExistence(timeout: 5), "One click selects, right after Select")
        // One trash button, then a choice like Photos: remove from this Mac only, or delete everywhere.
        app.buttons["Delete"].firstMatch.click()
        let confirm = app.buttons["Delete Everywhere"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "It asks first")
        shot("delete-confirm")
        confirm.click()
        XCTAssertTrue(containing("Recently Deleted").waitForExistence(timeout: 15), "It answers")
        shot("delete-answer")
        open("Recently Deleted")
        sleep(1)
        shot("recently-deleted-after")
    }

    func testRightClickMenu() {
        open("Library")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        tiles.firstMatch.rightClick()
        for title in ["Open", "Get Info", "Share…", "Export to Folder…", "Export Unmodified Original…", "Delete…"] {
            XCTAssertTrue(app.menuItems[title].firstMatch.waitForExistence(timeout: 5), "\(title) is in the menu")
        }
        shot("context-menu")
        app.menuItems["Get Info"].firstMatch.click()
        sleep(1)
        shot("info-panel")
        tiles.firstMatch.rightClick()
        app.menuItems["Open"].firstMatch.click()
        XCTAssertTrue(app.buttons["Back"].firstMatch.waitForExistence(timeout: 15), "Open opens the viewer")
    }

    func testViewerButtons() {
        open("Library")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        tiles.firstMatch.doubleClick()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "Double click opens the viewer")
        sleep(1)
        shot("viewer")
        app.typeKey(.rightArrow, modifierFlags: [])
        sleep(1)
        shot("viewer-next")
        app.buttons["Info"].firstMatch.click()
        sleep(1)
        shot("viewer-info")
        app.buttons["Info"].firstMatch.click()
        back.click()
        XCTAssertFalse(back.waitForExistence(timeout: 3), "Back closes it")
    }

    func testMenuBarCommands() {
        open("Library")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30))
        for title in ["Zoom In", "Zoom Out", "Show Info", "What the Icons Mean"] {
            XCTAssertTrue(app.menuBars.menuItems[title].firstMatch.exists, "\(title) is in the menu bar")
            app.menuBars.menuItems[title].firstMatch.click()
            sleep(1)
        }
        XCTAssertGreaterThan(app.windows.count, 1, "What the Icons Mean opens its window")
        shot("legend")
    }

    func testBackupPageControls() {
        open("Backup")
        for title in ["Free Up Space", "Save All to Photos", "Duplicates"] {
            let row = labelled(title)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(title) is on the Backup page")
            row.click()
            sleep(2)
            shot("tool-\(title)")
            let back = app.buttons["Back"].firstMatch
            if back.exists { back.click() } else { app.typeKey("[", modifierFlags: .command) }
            sleep(1)
        }
        for title in ["Back Up Automatically", "Wi-Fi Only", "Only on Power Adapter"] {
            let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "\(title) is a switch")
            let before = toggle.value as? Int
            toggle.click()
            sleep(1)
            XCTAssertNotEqual(toggle.value as? Int, before, "\(title) flips")
        }
        shot("backup-after-toggles")
        labelled("What the icons on photos mean").click()
        sleep(1)
        XCTAssertGreaterThan(app.windows.count, 1, "The icons link opens its window")
    }

    func testEverySettingsTab() {
        app.typeKey(",", modifierFlags: .command)
        for title in ["Backup", "Libraries", "Memories", "Storage", "Second Copy", "Export", "Logs", "About", "General"] {
            let tab = app.toolbars.buttons[title].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "\(title) is a Settings tab")
            tab.click()
            sleep(1)
            shot("settings-\(title)")
        }
        let signOut = app.buttons["Sign Out and Reset This Mac…"].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.click()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Sign out asks first")
        shot("settings-signout-confirm")
        cancel.click()
    }

    func testSearchControls() {
        open("Search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.click()
        // On this keyboard layout XCUITest holds Command for some letters (a, b, c, h, i, j, k, p, q, r, s, x, y…, seen in
        // the app's key events), so type only letters it sends plainly.
        field.typeText("novem")
        XCTAssertEqual(field.value as? String, "novem", "No letter is lost while the results appear")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "Typing finds items")
        shot("search-typed")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).click()  // the × isn't exposed on its own
        XCTAssertEqual(field.value as? String ?? "", "", "× empties the field")
        XCTAssertTrue(labelled("Months").waitForExistence(timeout: 10), "Clearing shows suggestions again")
        shot("search-cleared")
        labelled("Kochi").click()
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "A place finds items")
    }

    func testMemoriesCardSizeAndStory() {
        open("Memories")
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent Highlights,")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertLessThanOrEqual(card.frame.width, 460, "A card doesn't fill the whole window")
        shot("memories-grid")
        card.click()
        let show = app.buttons["Show All"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 15))
        show.click()
        sleep(2)
        shot("memory-show-all")
    }
}
