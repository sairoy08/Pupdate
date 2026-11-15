import XCTest

/// Not a pass/fail test: scrolls each screen and attaches screenshots for design review.
final class ScreenshotTour: XCTestCase {
    let server = "https://45-76-67-21.sslip.io"

    private func save(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func post(_ path: String) {
        var r = URLRequest(url: URL(string: server + path)!); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = "{}".data(using: .utf8)
        let e = expectation(description: path)
        URLSession.shared.dataTask(with: r) { _, _, _ in e.fulfill() }.resume()
        wait(for: [e], timeout: 10)
    }

    func testSatelliteShots() {
        post("/demo/reset")
        post("/demo/start")
        let app = XCUIApplication()
        app.launchArguments = ["-wb.role", "walker", "-wb.server", server]
        app.launch()
        sleep(6)
        app.swipeUp(); sleep(1); app.swipeUp(); sleep(6); save("s1-walk-map")
        let end = app.buttons["End demo walk"]
        if end.waitForExistence(timeout: 5) { end.tap() }
        let whereTo = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Where to tonight?")).firstMatch
        _ = whereTo.waitForExistence(timeout: 10); whereTo.tap()
        let field = app.textFields.firstMatch
        _ = field.waitForExistence(timeout: 5); field.tap(); field.typeText("Tooker House\n")
        sleep(12); save("s2-plan-map")
    }

    func testCustomizeShot() {
        post("/demo/reset")
        let app = XCUIApplication()
        app.launchArguments = ["-wb.role", "walker", "-wb.server", server]
        app.launch()
        let c = app.buttons["Customize"].firstMatch
        _ = c.waitForExistence(timeout: 10); c.tap(); sleep(2)
        app.buttons["Otter"].firstMatch.tap(); sleep(1); save("c1-otter")
        app.swipeUp(); sleep(1); save("c2-grid")
    }

    func testTour() {
        post("/demo/reset")
        let app = XCUIApplication()
        app.launchArguments = ["-wb.role", "walker", "-wb.server", server]
        app.launch()
        sleep(4); save("01-home-top")
        app.swipeUp(); sleep(1); save("02-home-mid")
        app.swipeUp(); sleep(1); save("03-home-bottom")
        app.swipeDown(); app.swipeDown(); sleep(1)
        app.buttons["Settings"].tap(); sleep(2); save("09-settings")
        app.swipeUp(); sleep(1); save("10-settings-bottom")
        app.buttons["Close settings"].tap(); sleep(1)
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Where to tonight?")).firstMatch.tap()
        let field = app.textFields.firstMatch
        _ = field.waitForExistence(timeout: 5); field.tap(); field.typeText("Vista del Sol\n")
        sleep(9); save("11-plan-routes")
        app.buttons["Back"].firstMatch.tap(); sleep(1)

        post("/demo/start")
        sleep(18) // first scripted check-in
        save("04-walk-top")
        app.swipeUp(); sleep(1); save("05-walk-mid")
        app.swipeUp(); sleep(1); save("06-walk-bottom")
        app.terminate()

        let friend = XCUIApplication()
        friend.launchArguments = ["-wb.role", "friend", "-wb.server", server]
        friend.launch()
        sleep(4); save("07-friend-top")
        friend.swipeUp(); sleep(1); save("08-friend-mid")
    }
}
