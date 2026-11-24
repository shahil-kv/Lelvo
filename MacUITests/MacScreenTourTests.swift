import XCTest

/// The Mac's first-run screens in light and dark mode, saved as PNGs (`CG_SCREENSHOT_DIR`) or test attachments.
/// Runs `LelvoMacTestApp`, never the real app.
final class MacScreenTourTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testOnboardingLight() { tour("light") }
    func testOnboardingDark() { tour("dark") }

    private func tour(_ look: String) {
        XCTAssertEqual(Bundle(for: Self.self).bundleIdentifier?.hasPrefix("app.lelvo.mac.uitests"), true)
        let app = XCUIApplication()
        app.launchArguments = ["-UITestReset", "-UITestAppearance", look]
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["Get started"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        sleep(2); shot(app, "\(look)-01-intro")
        start.click()
        let next = app.buttons["Continue"], last = app.buttons["Continue to Lelvo"]
        var page = 2
        while next.waitForExistence(timeout: 5), !last.exists, page < 7 {
            sleep(1); shot(app, "\(look)-0\(page)-intro"); page += 1
            next.click()
        }
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        sleep(1); shot(app, "\(look)-0\(page)-intro")
        last.click()
        let signIn = app.buttons["Continue with Telegram"], notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 3), !signIn.exists { sleep(1); shot(app, "\(look)-08-photos"); notNow.click() }
        else if signIn.exists { signIn.click() }
        sleep(2); shot(app, "\(look)-09-signin")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.windows.firstMatch.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["CG_SCREENSHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
