import XCTest

/// The Takeout guides under Backup → Tools. `-uitestTakeoutFixture` loads a tiny plan instead of the user's files,
/// so opening Import never waits on the system file picker.
final class TakeoutGuideTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-uitestTakeoutFixture"]
        app.launch()
        app.openDemoLibrary()
        app.buttons["Backup"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 15))
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    func testBothGuidesShowTheSteps() {
        let shared = [
            "Open Google Takeout and sign in with the Google account that has your photos.",
            "Deselect all",
            "Send download link via email",
            "Export once",
            "Wait for Google's email",
            "Download the first zip into Files",
            "Come back here and tap",
            "When Lelvo says a zip is done",
            "Wi-Fi recommended",
            "expire after 7 days",
        ]

        openGuide("Import from Google Photos", title: "Google Photos")
        shot("guide-photos-light")
        requireTexts(shared + ["select only Google Photos"])
        shot("guide-photos-light-scrolled")
        openImport()
        shot("import-light")
        app.swipeUp()
        shot("import-light-actions")
        pop(to: "Google Photos")
        pop(to: "Backup")

        openGuide("Import from Google Drive", title: "Google Drive")
        shot("guide-drive-light")
        requireTexts(shared + ["select only Drive"])
        shot("guide-drive-light-scrolled")
        pop(to: "Backup")

        XCUIDevice.shared.appearance = .dark
        sleep(1)

        openGuide("Import from Google Photos", title: "Google Photos")
        shot("guide-photos-dark")
        requireTexts(["select only Google Photos", "Open Google Takeout and sign in"])
        pop(to: "Backup")

        openGuide("Import from Google Drive", title: "Google Drive")
        shot("guide-drive-dark")
        requireTexts(["select only Drive", "Send download link via email"])
        openImport()
        shot("import-dark")
        app.swipeUp()
        shot("import-dark-actions")
    }

    private func openGuide(_ label: String, title: String) {
        for _ in 0..<4 { app.swipeDown() }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.isHittable, "\(label) should be on the Backup tab")
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func openImport() {
        let choose = app.buttons["Choose files"].firstMatch
        for _ in 0..<4 { app.swipeDown() }
        for _ in 0..<8 where !(choose.exists && choose.isHittable) { app.swipeUp() }
        XCTAssertTrue(choose.isHittable, "Choose files should be on the guide")
        choose.tap()
        XCTAssertTrue(app.navigationBars["Import"].waitForExistence(timeout: 5))
        let plan = element(containing: "LelvoTakeoutFixture")
        XCTAssertTrue(plan.waitForExistence(timeout: 30), "The sample plan should load without real files")
    }

    private func requireTexts(_ fragments: [String], file: StaticString = #filePath, line: UInt = #line) {
        var pending = fragments
        for _ in 0..<8 {
            pending.removeAll { element(containing: $0).exists }
            if pending.isEmpty { return }
            app.swipeUp()
        }
        XCTAssertTrue(pending.isEmpty, "Missing: \(pending.joined(separator: " | "))", file: file, line: line)
    }

    private func element(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func pop(to title: String) {
        // The floating back control's identifier is BackButton. Older systems use the previous title.
        let floating = app.buttons["BackButton"]
        let titled = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        let button = floating.exists ? floating : titled
        XCTAssertTrue(button.waitForExistence(timeout: 3), "Back to \(title)")
        button.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let dir = URL(fileURLWithPath: "/Users/shahil/Documents/Coding/Personal/Memvo/build/screenshots/takeout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
