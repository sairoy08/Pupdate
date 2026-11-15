import XCTest

/// End-to-end: the real app, tapping through the demo, against the real backend on localhost:8100.
final class PupdateE2ETests: XCTestCase {
    /// The live server by default; set TEST_RUNNER_WB_SERVER (e.g. http://localhost:8100) to test a local backend
    /// without disturbing phones that are using the live one.
    let server = ProcessInfo.processInfo.environment["WB_SERVER"] ?? "https://45-76-67-21.sslip.io"

    override func setUp() { continueAfterFailure = false }

    private func api(_ path: String, _ body: String = "{}") {
        var req = URLRequest(url: URL(string: server + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    private func launch(role: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-wb.role", role, "-wb.server", server]
        app.launch()
        return app
    }

    /// Scroll until a button exists and is hittable (SwiftUI drops far off-screen rows from the tree).
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let b = app.buttons[label].firstMatch
        var tries = 0
        while !(b.exists && b.isHittable) && tries < 8 { app.swipeUp(); tries += 1 }
        return b
    }

    private func text(_ app: XCUIApplication, _ s: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    /// Walker answers the first check-in by petting: +10 XP and the evolution celebration.
    func testWalkerPetsAndEvolves() {
        api("/demo/reset")
        api("/users/jordan/buddy", "{\"name\":\"Melvin\",\"species\":\"dog\"}")
        api("/demo/start")
        let app = launch(role: "walker")
        XCTAssertTrue(text(app, "Still good?").waitForExistence(timeout: 30), "check-in never showed")
        // A tap must not count: petting needs a real rub across the buddy.
        let buddy = app.buttons["Your buddy"].firstMatch
        buddy.tap()
        XCTAssertFalse(app.buttons["Awesome"].waitForExistence(timeout: 2), "a tap should not pet")
        let from = buddy.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        let to = buddy.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertTrue(app.buttons["Awesome"].waitForExistence(timeout: 8), "evolution overlay never showed")
        app.buttons["Awesome"].tap()
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 8))
        XCTAssertTrue(text(app, "Scout Pup").waitForExistence(timeout: 5))
    }

    /// Friend runs the demo panel: start, stop answering, the alert takeover, close.
    func testFriendGetsAlertAndClosesIt() {
        let app = launch(role: "friend")
        reveal(app, "Reset").tap()
        reveal(app, "Start walk").tap()
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        XCTAssertTrue(text(app, "All good").waitForExistence(timeout: 10), "walk never appeared for the friend")
        reveal(app, "Stop answering").tap()
        // Wait for the takeover itself (the walk log also mentions "stopped answering" right away).
        let close = app.buttons["I've reached Jordan, close alert"]
        XCTAssertTrue(close.waitForExistence(timeout: 60), "alert takeover never showed")
        XCTAssertTrue(text(app, "Jordan stopped answering").exists)
        XCTAssertTrue(app.buttons["Call Jordan"].exists, "call button missing on the alert")
        close.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["I've reached Jordan, close alert"])
        waitForExpectations(timeout: 10)
    }

    /// Duress from the API reaches the friend with no call button.
    func testDuressHidesCallButton() {
        let app = launch(role: "friend")
        reveal(app, "Reset").tap()
        reveal(app, "Start walk").tap()
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        XCTAssertTrue(text(app, "All good").waitForExistence(timeout: 10))
        // The walker's long-press calls /duress; trigger the same call directly.
        var walkId = ""
        let got = expectation(description: "user")
        URLSession.shared.dataTask(with: URL(string: server + "/users/jordan")!) { d, _, _ in
            walkId = ((try? JSONSerialization.jsonObject(with: d ?? Data())) as? [String: Any])?["active_walk_id"] as? String ?? ""
            got.fulfill()
        }.resume()
        wait(for: [got], timeout: 10)
        api("/walks/\(walkId)/duress")
        XCTAssertTrue(text(app, "sent a silent alert").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Call Jordan"].exists)
        app.buttons["I've reached Jordan, close alert"].tap()
    }

    /// Settings opens from home and shows the real toggles.
    func testSettingsOpens() {
        api("/demo/reset")
        let app = launch(role: "walker")
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        XCTAssertTrue(app.staticTexts["Default route"].waitForExistence(timeout: 5))
        sleep(6) // the home screen keeps polling underneath; Settings must stay open
        XCTAssertTrue(app.staticTexts["Default route"].exists, "Settings closed by itself")
        XCTAssertTrue(app.switches.count >= 3)
        app.buttons["Close settings"].tap()
    }

    /// Walker plans a destination on the map page and starts a demo walk along Apple's route.
    func testPlanDestinationAndStartWalk() {
        api("/demo/reset")
        let app = launch(role: "walker")
        let whereTo = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Where to tonight?")).firstMatch
        XCTAssertTrue(whereTo.waitForExistence(timeout: 10))
        whereTo.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Tooker House\n")
        // Safer and quickest options (one card when Apple returns a single route).
        let options = app.buttons.matching(NSPredicate(format: "label == 'Safer route' OR label == 'Quickest route'"))
        let anyOption = options.firstMatch
        XCTAssertTrue(anyOption.waitForExistence(timeout: 20), "no route options")
        if app.buttons["Quickest route"].exists { app.buttons["Quickest route"].tap() }
        // "Safety notes by Gemini" with a key, "Safety picked by street type" without one (the fallback).
        XCTAssertTrue(text(app, "A guide, not a guarantee").waitForExistence(timeout: 15), "no route safety notes")
        let go = app.buttons["Walk with Melvin"]
        XCTAssertTrue(go.waitForExistence(timeout: 20), "no trip sheet")
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: go)
        waitForExpectations(timeout: 20)
        go.tap()
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 15), "walk screen never showed")
        XCTAssertTrue(text(app, "Tooker House").waitForExistence(timeout: 5))
    }

    /// A real GPS walk (demo off) plus the Live Activity: the shell feeds simulated GPS meanwhile.
    func testRealGPSWalkAndLiveActivity() {
        api("/demo/reset")
        let app = launch(role: "walker")
        let whereTo = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Where to tonight?")).firstMatch
        XCTAssertTrue(whereTo.waitForExistence(timeout: 10))
        whereTo.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Tooker House\n")
        let demo = app.switches.firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 20))
        if (demo.value as? String) == "1" { demo.switches.firstMatch.tap() }
        let go = app.buttons["Walk with Melvin"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: go)
        waitForExpectations(timeout: 20)
        go.tap()
        XCTAssertTrue(app.buttons["I'm home"].waitForExistence(timeout: 15), "real walk did not start")
        sleep(25) // the shell moves the simulated GPS now
        let shot = { (name: String) in
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; self.add(a)
        }
        shot("la-1-in-app")
        XCUIDevice.shared.press(.home)
        sleep(4); shot("la-2-home-dynamic-island")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(3); XCUIDevice.shared.press(.home); sleep(3); shot("la-3-lock-screen")
        app.activate()
        let end = app.buttons["I'm home"]
        if end.waitForExistence(timeout: 10) { end.tap() }
    }

    private func rub(_ app: XCUIApplication) {
        let buddy = app.buttons["Your buddy"].firstMatch
        let from = buddy.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        let to = buddy.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    private func launch(role: String, extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-wb.role", role, "-wb.server", server] + extra
        app.launch()
        return app
    }

    /// Pet three check-ins in a row, then pet one late: XP 90 -> 100 -> 110 -> 120, late adds nothing.
    func testPettingAtIntervals() {
        api("/demo/reset")
        api("/users/jordan/buddy", "{\"name\":\"Melvin\",\"species\":\"chick\"}")
        api("/demo/start")
        let app = launch(role: "walker", extra: ["-wb.petStyle", "rub"])
        for (i, xp) in [100, 110, 120].enumerated() {
            api("/demo/checkin")
            XCTAssertTrue(text(app, "Still good?").waitForExistence(timeout: 15), "check-in \(i + 1) never showed")
            rub(app)
            if i == 0 {
                XCTAssertTrue(app.buttons["Awesome"].waitForExistence(timeout: 8), "no evolution on the first pet")
                app.buttons["Awesome"].tap()
            }
            XCTAssertTrue(text(app, "\(xp) / 250 XP").waitForExistence(timeout: 8), "XP did not reach \(xp)")
            XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 5))
        }
        // Late: wait past the 30 s check-in window (15 s real at 2x), then pet.
        api("/demo/checkin")
        XCTAssertTrue(text(app, "Still good?").waitForExistence(timeout: 15))
        XCTAssertTrue(text(app, "Hey, you there?").waitForExistence(timeout: 25), "never reached the nudge stage")
        rub(app)
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 8))
        XCTAssertTrue(text(app, "120 / 250 XP").exists, "a late pet must not give XP")
    }

    /// Accessibility: with tap-to-pet on, a tap answers the check-in.
    func testTapToPetOption() {
        api("/demo/reset")
        api("/demo/start")
        let app = launch(role: "walker", extra: ["-wb.petStyle", "tap"])
        api("/demo/checkin")
        XCTAssertTrue(text(app, "Still good?").waitForExistence(timeout: 15))
        app.buttons["Your buddy"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Awesome"].waitForExistence(timeout: 8), "tap-to-pet did not pet")
    }

    /// Circle: add a friend in Settings, see them, remove them.
    func testAddAndRemoveFriend() {
        api("/demo/reset")
        let app = launch(role: "walker")
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10)); gear.tap()
        let name = app.textFields["Name"]
        var tries = 0
        while !(name.exists && name.isHittable) && tries < 10 { app.swipeUp(); tries += 1 }
        name.tap(); name.typeText("Alex Test")
        let phone = app.textFields["Phone (for the Call button)"]
        phone.tap(); phone.typeText("4805550199")
        let add = app.buttons["Add to circle"]
        if !add.isHittable { app.swipeUp() }
        add.tap()
        let remove = app.buttons["Remove Alex Test from your circle"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "added friend not listed")
        remove.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: remove)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["Remove Maya from your circle"].exists)
    }

    /// Accessibility settings exist and the largest text size still lays out.
    func testAccessibilitySettings() {
        api("/demo/reset")
        let app = launch(role: "walker", extra: ["-wb.textScale", "1.3"])
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Where to tonight?")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        for label in ["Spoken prompts", "Sounds", "Strong vibration for alerts", "Reduce motion", "Haptics", "Satellite map"] {
            let sw = app.switches.containing(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            var tries = 0
            while !sw.exists && tries < 8 { app.swipeUp(); tries += 1 }
            XCTAssertTrue(sw.exists, "missing setting: \(label)")
        }
    }

    private func get(_ path: String) -> Any? {
        var out: Any?
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: URL(string: server + path)!) { d, _, _ in
            out = d.flatMap { try? JSONSerialization.jsonObject(with: $0) }; done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return out
    }

    private func delete(_ path: String) {
        var req = URLRequest(url: URL(string: server + path)!)
        req.httpMethod = "DELETE"
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) {
        var tries = 0
        while !(el.exists && el.isHittable) && tries < 10 { app.swipeUp(); tries += 1 }
    }

    /// Scroll back up from the page margin: a swipe that starts on the live map pans the map instead of the page.
    private func scrollUpTo(_ app: XCUIApplication, _ el: XCUIElement) {
        var tries = 0
        while !(el.exists && el.isHittable) && tries < 10 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.9)))
            tries += 1
        }
    }

    /// Turn-by-turn: the demo route shows the next turn and the distance to it.
    func testNextTurnCard() {
        api("/demo/reset")
        api("/demo/start")
        let app = launch(role: "walker")
        XCTAssertTrue(text(app, "Orange Mall").waitForExistence(timeout: 15), "next turn card missing")
        XCTAssertTrue(app.descendants(matching: .any)["next-turn"].exists)
    }

    /// One phone: the walker's own Test tools make the demo walker run; Gemini (or the safe fallback)
    /// checks in, the pace card says Running, and the walk log records the judgment.
    func testOnePhonePaceToolsTriggerCheckin() {
        api("/demo/reset")
        api("/demo/start")
        let app = launch(role: "walker")
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 15))
        // Answer the scripted first check-in so the pace check-in is the next one.
        XCTAssertTrue(text(app, "Still good?").waitForExistence(timeout: 30))
        rub(app)
        if app.buttons["Awesome"].waitForExistence(timeout: 6) { app.buttons["Awesome"].tap() }
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 8))
        let run = app.buttons["Run"].firstMatch
        scrollTo(app, run)
        XCTAssertTrue(run.exists, "test tools missing on the walk screen")
        run.tap()
        XCTAssertTrue(text(app, "Running").waitForExistence(timeout: 30), "pace card never showed running")
        XCTAssertTrue(text(app, "Still good?").waitForExistence(timeout: 30), "pace never triggered a check-in")
        scrollUpTo(app, app.buttons["Your buddy"].firstMatch)
        rub(app)
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 8))
        let judged = text(app, "Gemini:")
        scrollTo(app, judged)
        XCTAssertTrue(judged.exists || text(app, "Started running").exists, "walk log missing the pace entry")
    }

    /// Flags: open Flagged spots, drop a flag at the map center, see the active count go up.
    func testAddFlagFromPhone() {
        api("/demo/reset")
        let app = launch(role: "walker")
        let open = app.buttons["open-flags"]
        scrollTo(app, open)
        open.tap()
        XCTAssertTrue(text(app, "2 active").waitForExistence(timeout: 10), "seeded flags missing")
        app.buttons["Flag the map center"].tap()
        app.buttons["Construction"].tap()
        app.buttons["Share with my circle"].tap()
        XCTAssertTrue(text(app, "3 active").waitForExistence(timeout: 10), "new flag not saved")
        // Clean up: delete Jordan's flags.
        for f in (get("/flags?viewer=jordan") as? [[String: Any]]) ?? [] where (f["by"] as? String) == "jordan" {
            delete("/flags/\(f["id"]!)?by=jordan")
        }
    }

    /// Settings: a 1-hour check-in gap warns; turning check-ins off asks first.
    func testTimingWarningsAndCheckinsOff() {
        api("/demo/reset")
        let app = launch(role: "walker")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let hour = app.buttons["1 hour"]
        XCTAssertTrue(hour.waitForExistence(timeout: 10)); hour.tap()
        XCTAssertTrue(text(app, "every 60 min").waitForExistence(timeout: 10), "no long-gap warning")
        app.buttons["Only if off"].tap()
        let toggle = app.switches["checkins-toggle"]
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(app.alerts["Turn check-ins off?"].waitForExistence(timeout: 5), "no confirmation")
        app.alerts.buttons["Turn off"].tap()
        XCTAssertTrue(text(app, "Off: only the silent alert").waitForExistence(timeout: 5))
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(text(app, "Melvin checks in and alerts").waitForExistence(timeout: 5))
        let total = app.staticTexts["alert-total"]
        scrollTo(app, total)
        XCTAssertTrue(total.label.contains("1 min 50 s"), "default ladder total wrong: \(total.label)")
    }

    /// The friend sees the warning when the walker picked a 30-minute check-in gap.
    func testFriendSeesLongGapNotice() {
        api("/demo/reset")
        api("/walks", "{\"walker_id\":\"jordan\",\"route_id\":\"library-to-tooker\",\"demo\":false,\"checkin_every_s\":1800}")
        let app = launch(role: "friend")
        XCTAssertTrue(text(app, "every 30 min").waitForExistence(timeout: 15), "friend never saw the notice")
        api("/demo/reset")
    }

    /// End a walk early: pick a reason, the walk ends, and the friend sees why.
    func testEndWalkEarly() {
        api("/demo/reset")
        api("/demo/start")
        let app = launch(role: "walker")
        let endEarly = app.buttons["End walk early"]
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 15))
        scrollTo(app, endEarly)
        endEarly.tap()
        XCTAssertTrue(text(app, "End walk early?").waitForExistence(timeout: 5))
        app.buttons["Got a ride"].tap()
        app.buttons["End walk"].tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Where to tonight?")).firstMatch
            .waitForExistence(timeout: 10), "walk didn't end")
        let feed = get("/friends/maya/feed") as? [String: Any]
        let ups = feed?["updates"] as? [[String: Any]] ?? []
        XCTAssertTrue((ups.first?["text"] as? String ?? "").contains("got a ride"), "friend wasn't told")
        app.terminate()
        let friend = launch(role: "friend")
        XCTAssertTrue(text(friend, "ended the walk early").waitForExistence(timeout: 10), "friend screen missing the update")
    }

    /// Demo walker controls: pause holds the walker, 8x and Arrive walk it home and end the walk.
    func testDemoWalkerControls() {
        api("/demo/reset")
        api("/demo/start")
        let app = launch(role: "walker")
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 15))
        let pause = app.buttons["Pause"]
        scrollTo(app, pause)
        XCTAssertTrue(pause.exists, "no demo walker controls")
        pause.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5), "pause didn't take")
        let sim = (get("/users/jordan/active") as? [String: Any])?["sim"] as? [String: Any]
        XCTAssertEqual(sim?["paused"] as? Bool, true)
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        api("/demo/control", "{\"action\":\"jump\",\"value\":0.9}")
        app.buttons["Speed 8 times"].tap()
        let arrive = app.buttons["Arrive"]
        scrollTo(app, arrive)
        arrive.tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Where to tonight?")).firstMatch
            .waitForExistence(timeout: 40), "walker never arrived")
        let trips = get("/users/jordan/trips") as? [[String: Any]] ?? []
        XCTAssertEqual(trips.first?["to"] as? String, "Tooker House")
        XCTAssertNil(trips.first?["ended_early"] as? String)
        api("/demo/reset")
    }

    /// Trip history: a walk that just ended is on top of Past walks, above the seeded ones.
    func testTripHistoryShowsEndedWalk() {
        api("/demo/reset")
        api("/demo/start")
        let app = launch(role: "walker")
        let endEarly = app.buttons["End walk early"]
        XCTAssertTrue(text(app, "Walking together").waitForExistence(timeout: 15))
        scrollTo(app, endEarly)
        endEarly.tap()
        app.buttons["Got a ride"].tap()
        app.buttons["End walk"].tap()
        let open = app.buttons["open-trips"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "walk didn't end")
        scrollTo(app, open)
        open.tap()
        XCTAssertTrue(text(app, "Past walks").waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, "Ended early: got a ride").waitForExistence(timeout: 10), "the walk that just ended is missing")
        let trips = get("/users/jordan/trips") as? [[String: Any]] ?? []
        XCTAssertEqual(trips.count, 3)
        XCTAssertEqual(trips.first?["ended_early"] as? String, "got a ride")
        api("/demo/reset")
    }
}
