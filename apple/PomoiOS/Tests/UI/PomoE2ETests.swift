import UIKit
import XCTest

/// End-to-end flows: the real app in the simulator against a real `pomod` (`pomod --home /tmp/pomo-ios-e2e
/// --port 0 --sync n0 --name e2e-mac`). Tests run in name order and share the app's data: the first pairs the
/// phone, later ones pair again if an earlier one revoked it.
///
/// Screenshots go to `POMO_E2E_SHOTS` (a directory; `TEST_RUNNER_POMO_E2E_SHOTS` for xcodebuild) as
/// `ios-e2e-<name>.png`, and are attached to the result bundle.
final class PomoE2ETests: XCTestCase {
    var app: XCUIApplication!
    var daemon: Daemon!
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        daemon = try Daemon.connect()
        try daemon.stopIfLive()
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Timer"].waitForExistence(timeout: 30), "app did not reach its tab bar")
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 { shot("FAILED-\(name.split(separator: " ").last?.dropLast() ?? "test")") }
    }

    // MARK: 1 Timer

    func test01_timerFlow() throws {
        try ensureIdle()
        XCTAssertEqual(phase().label, "Ready")
        let start = app.buttons["Start focus · 25 min"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        shot("timer-idle")

        // Label, then start.
        let label = app.textFields["Label"]
        label.tap()
        label.typeText("e2e focus\n")
        start.tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        XCTAssertEqual(phase().label, "Focus")
        XCTAssertEqual(label.value as? String, "e2e focus")

        // The countdown ticks.
        let t0 = try remainingSeconds()
        XCTAssertTrue((24 * 60 + 50...25 * 60).contains(t0), "fresh block shows ~25:00, got \(t0)s")
        sleep(3)
        let t1 = try remainingSeconds()
        XCTAssertLessThanOrEqual(t1, t0 - 2, "countdown ticked: \(t0)s -> \(t1)s")
        shot("timer-running")
        XCTAssertEqual(try daemon.timerStatus(), "idle", "not paired yet: the phone block stays on the phone")

        // Pause freezes it.
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        XCTAssertEqual(phase().label, "Paused")
        let p0 = try remainingSeconds()
        sleep(3)
        XCTAssertEqual(try remainingSeconds(), p0, "paused countdown does not move")
        shot("timer-paused")

        // Resume.
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        XCTAssertEqual(phase().label, "Focus")
        sleep(2)
        XCTAssertLessThan(try remainingSeconds(), p0, "resumed countdown moves again")

        // +5 min.
        let before = try remainingSeconds()
        app.buttons["+5 min"].tap()
        try eventually("remaining grows by 5 min") { try self.remainingSeconds() > before + 290 }

        // Reset restarts from the planned length (25 min, extension discarded).
        app.buttons["Reset"].tap()
        try eventually("reset to the planned length") {
            let r = try self.remainingSeconds()
            return r > 24 * 60 + 40 && r <= 25 * 60
        }

        // Skip ends the block.
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.buttons["Start focus · 25 min"].waitForExistence(timeout: 5))
        XCTAssertEqual(phase().label, "Ready")
        XCTAssertTrue(app.staticTexts["Last: focus skipped"].exists, "last block summary after skip")
        shot("timer-after-skip")

        // Kind picker: a short break.
        app.segmentedControls.buttons["Short break"].tap()
        let startBreak = app.buttons["Start short break · 5 min"]
        XCTAssertTrue(startBreak.waitForExistence(timeout: 5))
        shot("timer-kind-picker")
        startBreak.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        XCTAssertEqual(phase().label, "Short break")
        XCTAssertLessThanOrEqual(try remainingSeconds(), 5 * 60)
        shot("timer-break")

        // Stop abandons.
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.staticTexts["Last: short break abandoned"].waitForExistence(timeout: 5))
        XCTAssertEqual(phase().label, "Ready")

        // A second focus block so Stats has more than one label and Stop is covered on focus too.
        app.segmentedControls.buttons["Focus"].tap()
        app.buttons["Start focus · 25 min"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.staticTexts["Last: focus abandoned"].waitForExistence(timeout: 5))
    }

    // MARK: 2 Devices: scanner sheet, paste, join

    func test02a_scannerSheet() throws {
        app.tabBars.buttons["Devices"].tap()
        XCTAssertTrue(app.navigationBars["Devices"].waitForExistence(timeout: 5))
        shot("devices-before-pairing")

        // The scanner sheet opens. The simulator has no camera: expect the "no camera" or the "access is off" text.
        app.buttons["Scan QR code"].tap()
        XCTAssertTrue(app.navigationBars["Scan to pair"].waitForExistence(timeout: 5), "scanner sheet opened")
        let cameraAlert = springboard.alerts.firstMatch
        if cameraAlert.waitForExistence(timeout: 3) {
            shot("scanner-camera-permission")
            for name in ["Allow", "OK", "Don’t Allow", "Don't Allow"] where cameraAlert.buttons[name].exists {
                cameraAlert.buttons[name].tap()
                break
            }
        }
        let unavailable = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'No camera is available' OR label BEGINSWITH 'Camera access is off'"
        )).firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10), "scanner sheet explains why there is no camera")
        shot("scanner-sheet-\(cameraStateName(unavailable.label))")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Devices"].waitForExistence(timeout: 5), "sheet dismissed")
    }

    func test02b_pasteTicketAndJoin() throws {
        app.tabBars.buttons["Devices"].tap()
        try pairWithMac(screenshotName: "devices-paired")
        XCTAssertTrue(try daemon.peers().contains { ($0["paired"] as? Bool) == true && ($0["revoked"] as? Bool) != true },
                      "the daemon lists the phone as a paired device")
    }

    // MARK: 3 Cross-device

    func test03_crossDevice() throws {
        try ensurePaired()
        app.tabBars.buttons["Timer"].tap()

        // Mac -> phone: `pomo start --label from-mac`.
        try daemon.start(minutes: 25, label: "from-mac")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 30), "block started on the Mac shows on the phone")
        try eventually("label from the Mac", timeout: 5) { (self.app.textFields["Label"].value as? String) == "from-mac" }
        XCTAssertEqual(phase().label, "Focus")
        XCTAssertFalse(app.staticTexts["timer.source"].exists, "a user-issued block shows no agent tag")
        shot("cross-mac-started-on-phone")

        // Phone -> Mac: pause in the app, the daemon must see it.
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        try eventually("daemon sees paused", timeout: 20) { try self.daemon.timerStatus() == "paused" }
        shot("cross-phone-paused")

        // Mac -> phone: resume on the daemon.
        try daemon.command("resume")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 30), "resume from the Mac reaches the phone")
        try daemon.command("stop")
        XCTAssertTrue(app.buttons["Start focus · 25 min"].waitForExistence(timeout: 30), "stop from the Mac reaches the phone")

        // An agent's block carries its name.
        try daemon.start(minutes: 25, label: "from-agent", source: "agent:e2e-claude")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["timer.source"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["timer.source"].label, "Started by e2e-claude")
        shot("cross-agent-block")
        try daemon.command("stop")
        XCTAssertTrue(app.buttons["Start focus · 25 min"].waitForExistence(timeout: 30))

        // Revoke from the app; afterwards events stop flowing both ways.
        app.tabBars.buttons["Devices"].tap()
        let row = app.buttons["Revoke e2e-mac"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let confirm = app.buttons["Revoke"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation dialog appeared")
        sleep(1)
        shot("devices-revoke-confirm")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Revoked"].waitForExistence(timeout: 5), "row says Revoked")
        shot("devices-revoked")

        try daemon.start(minutes: 25, label: "after-revoke-mac")
        app.tabBars.buttons["Timer"].tap()
        sleep(12)
        XCTAssertTrue(app.buttons["Start focus · 25 min"].exists, "a block started on the Mac after revoke does not reach the phone")
        XCTAssertNotEqual(phase().label, "Focus")
        try daemon.stopIfLive()

        app.buttons["Start focus · 25 min"].tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        sleep(10)
        XCTAssertEqual(try daemon.timerStatus(), "idle", "a block started on the phone after revoke does not reach the Mac")
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start focus · 25 min"].waitForExistence(timeout: 5))
    }

    // MARK: 4 Stats and Settings

    func test04_statsAndSettings() throws {
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["This week"].exists)
        XCTAssertTrue(app.staticTexts["Streak"].exists)
        // test01 ran focus blocks labelled "e2e focus": the label ranking lists it with a duration.
        let ranked = app.staticTexts["e2e focus"]
        for _ in 0..<4 where !ranked.exists { app.swipeUp() }
        XCTAssertTrue(ranked.exists, "label ranking lists the label used in test01")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        shot("stats-top")
        app.swipeUp()
        shot("stats-scrolled")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Focus: 25 min"].exists)
        XCTAssertTrue(app.staticTexts["Short break: 5 min"].exists)
        // The app was just launched and the Devices tab never opened: Settings must still show this device's name.
        let name = UIDevice.current.name
        let aboutDevice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name)).firstMatch
        XCTAssertTrue(aboutDevice.waitForExistence(timeout: 5), "About shows the device name")
        shot("settings")
    }

    // MARK: 5 Notification

    func test05_blockEndNotification() throws {
        try ensurePaired()
        app.tabBars.buttons["Timer"].tap()
        selectFocusKind()
        XCTAssertTrue(app.buttons["Start focus · 25 min"].waitForExistence(timeout: 10))

        // Mac starts a 0.2 min (12 s) block; the phone schedules a notification when it sees the event.
        try daemon.start(minutes: 0.2, label: "short e2e")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 30), "short block reached the phone")
        let started = Date()
        XCUIDevice.shared.press(.home)
        shot("notification-home-screen")

        // The banner shows for a few seconds after the block ends (12 s after it started). Poll fast.
        let deadline = Date().addingTimeInterval(40)
        var found: String?
        while Date() < deadline, found == nil {
            let hit = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Focus complete'")).firstMatch
            if hit.exists { found = hit.label; usleep(600_000); shot("notification-banner") }
            else { usleep(200_000) }
        }
        print("BANNER after \(Int(Date().timeIntervalSince(started))) s: \(found ?? "none")")
        if found == nil {
            // Maybe it was shown and gone: look in Notification Center.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.0))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8)))
            sleep(2)
            shot("notification-center")
            print("SPRINGBOARD:\n\(springboard.debugDescription)")
        }
        XCTAssertNotNil(found, "block-end banner appeared after the block ended")
    }

    // MARK: 6 Live Activity on the Lock Screen

    func test06_liveActivityOnLockScreen() throws {
        try ensureIdle()
        selectFocusKind()
        let label = app.textFields["Label"]
        label.tap()
        label.typeText("live activity\n")
        app.buttons["Start focus · 25 min"].tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("liveactivity-home-with-island")

        // There is no public lock API; the lock button selector works on current simulators.
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        shot("liveactivity-lock-screen")
        let allow = springboard.buttons["Allow"]
        if allow.exists {
            allow.tap()
            sleep(3)
            shot("liveactivity-lock-screen-allowed")
        }
        let onLockScreen = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'live activity' OR label CONTAINS[c] 'Focus'")).firstMatch
        let seen = onLockScreen.waitForExistence(timeout: 5)
        print("LOCKSCREEN live activity element: \(seen ? onLockScreen.label : "none")")

        // Wake and unlock, then end the block.
        XCUIDevice.shared.press(.home)
        springboard.swipeUp()
        app.activate()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start '")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(seen, "the Live Activity appears on the Lock Screen")
    }

    // MARK: 7 Home Screen widget

    /// Adds the small "Today's focus" widget through the real widget gallery, then reads it on the Home Screen.
    /// Adds one widget per run; the simulator is meant to be disposable.
    func test07_widgetOnHomeScreen() throws {
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 2)
        XCTAssertTrue(springboard.buttons["Edit"].waitForExistence(timeout: 5), "Home Screen entered edit mode")
        springboard.buttons["Edit"].tap()
        let addMenu = springboard.buttons["Add Widget"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.tap()
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Pomo")
        let result = springboard.staticTexts["Pomo"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), "Pomo is listed in the widget gallery")
        result.tap()
        XCTAssertTrue(springboard.staticTexts["Today's focus"].waitForExistence(timeout: 5))
        shot("widget-gallery")
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch
        add.tap()
        sleep(2)
        springboard.buttons["Done"].firstMatch.tap()
        sleep(3)
        shot("widget-home-screen")
        let widget = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Focus today'")).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 10), "the widget is on the Home Screen")
        print("WIDGET label: \(widget.label)")
        // An unsigned build (CODE_SIGNING_ALLOWED=NO) carries no App Group entitlement, so the widget cannot read the
        // app's snapshot and shows zero. With ad-hoc signing (POMO_E2E_SIGNED=1) it must show the app's data: earlier
        // tests completed a focus block.
        if ProcessInfo.processInfo.environment["POMO_E2E_SIGNED"] == "1" {
            XCTAssertFalse(widget.label.contains("0 blocks done"), "widget shows the app's data: \(widget.label)")
        }
    }

    // MARK: Helpers

    func phase() -> XCUIElement { app.staticTexts["timer.phase"] }

    func remainingSeconds() throws -> Int {
        let label = app.staticTexts["timer.countdown"].label
        let nums = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count == 2 else { throw Daemon.Failure("unparseable countdown label: \(label)") }
        return nums[0] * 60 + nums[1]
    }

    func ensureIdle() throws {
        if app.buttons["Stop"].exists {
            app.buttons["Stop"].tap()
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start '")).firstMatch.waitForExistence(timeout: 10))
    }

    /// After a completed focus block the app suggests a break; the tests that need a focus block pick it.
    func selectFocusKind() {
        let focus = app.segmentedControls.buttons["Focus"]
        if focus.exists, !focus.isSelected { focus.tap() }
    }

    func eventually(_ what: String, timeout: TimeInterval = 10, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            usleep(300_000)
        }
        XCTFail("timed out waiting for: \(what)")
        throw Daemon.Failure("timed out: \(what)")
    }

    func allowNotificationsIfAsked() {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 4) else { return }
        shot("notification-permission-alert")
        alert.buttons["Allow"].tap()
    }

    /// Pastes a fresh ticket from the daemon into the Devices tab and joins.
    func pairWithMac(screenshotName: String) throws {
        app.tabBars.buttons["Devices"].tap()
        let field = app.textFields["devices.ticket"]
        for _ in 0..<5 where !field.isHittable { app.swipeUp() }
        field.tap()
        field.typeText(try daemon.offerTicket())
        let pair = app.buttons["devices.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        pair.tap()
        XCTAssertTrue(app.staticTexts["e2e-mac"].waitForExistence(timeout: 60), "paired device listed with its name")
        for _ in 0..<5 where !app.staticTexts["devices.joinMessage"].exists { app.swipeUp() }
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        shot(screenshotName)
    }

    func ensurePaired() throws {
        app.tabBars.buttons["Devices"].tap()
        if app.buttons["Revoke e2e-mac"].waitForExistence(timeout: 3) { return }
        try pairWithMac(screenshotName: "devices-repaired")
    }

    func cameraStateName(_ label: String) -> String { label.hasPrefix("Camera access is off") ? "denied" : "no-camera" }

    func shot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["POMO_E2E_SHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ios-e2e-\(name).png"))
        }
    }
}
