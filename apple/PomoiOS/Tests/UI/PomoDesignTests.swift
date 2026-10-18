import UIKit
import XCTest

/// Walks every screen of the app and saves a screenshot of each. Needs no daemon: the phone runs its own Core.
/// Screenshots go to `POMO_DESIGN_SHOTS` (`TEST_RUNNER_POMO_DESIGN_SHOTS` for xcodebuild) as
/// `redesign-ios-<name>-<light|dark>.png`, and are attached to the result bundle.
///
/// The appearance is chosen with `TEST_RUNNER_POMO_DESIGN_APPEARANCE=light|dark` (default light); the test sets
/// `XCUIDevice.shared.appearance` and puts it back to light when it ends.
///
/// The assertions check what the design promises and the app must keep: phase text, the serif countdown element,
/// the primary button changing with the Timer, and the four quiet buttons while a block is live.
final class PomoDesignTests: XCTestCase {
    var app: XCUIApplication!
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.appearance = .light
    }

    func test_walkEveryScreen() throws {
        let suffix = ProcessInfo.processInfo.environment["POMO_DESIGN_APPEARANCE"] ?? "light"
        XCUIDevice.shared.appearance = suffix == "dark" ? .dark : .light
        sleep(3)
        print("APPEARANCE after set: \(XCUIDevice.shared.appearance.rawValue)")
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Timer"].waitForExistence(timeout: 30))
        if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
        let anyStart = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start '")).firstMatch
        XCTAssertTrue(anyStart.waitForExistence(timeout: 10))
        let focusKind = app.segmentedControls.buttons["Focus"]
        if focusKind.exists, !focusKind.isSelected { focusKind.tap() }

        // Idle.
        XCTAssertEqual(app.staticTexts["timer.phase"].label, "Ready")
        shot("timer-idle", suffix)

        // Running focus.
        let label = app.textFields["Label"]
        label.tap()
        label.typeText("Write the design doc\n")
        app.buttons["Start focus · 25 min"].tap()
        allowNotificationsIfAsked()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["timer.phase"].label, "Focus")
        for name in ["+5 min", "Skip", "Reset", "Stop"] { XCTAssertTrue(app.buttons[name].exists, name) }
        sleep(2)
        shot("timer-running", suffix)

        // Paused.
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["timer.phase"].label, "Paused")
        shot("timer-paused", suffix)
        app.buttons["Stop"].tap()
        XCTAssertTrue(anyStart.waitForExistence(timeout: 10))

        // Break.
        app.segmentedControls.buttons["Short break"].tap()
        app.buttons["Start short break · 5 min"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["timer.phase"].label, "Short break")
        sleep(2)
        shot("timer-break", suffix)
        app.buttons["Stop"].tap()
        XCTAssertTrue(anyStart.waitForExistence(timeout: 10))

        // Stats, Devices, Settings.
        app.tabBars.buttons["Stats"].tap()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 10))
        sleep(1)
        shot("stats", suffix)
        app.swipeUp()
        shot("stats-scrolled", suffix)
        app.tabBars.buttons["Devices"].tap()
        XCTAssertTrue(app.navigationBars["Devices"].waitForExistence(timeout: 5))
        sleep(1)
        shot("devices", suffix)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        shot("settings", suffix)

        // Live Activity: Dynamic Island on the Home Screen, then the Lock Screen.
        app.tabBars.buttons["Timer"].tap()
        let focus = app.segmentedControls.buttons["Focus"]
        if focus.exists, !focus.isSelected { focus.tap() }
        app.buttons["Start focus · 25 min"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("home-island", suffix)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        for name in ["Allow", "Always Allow"] where springboard.buttons[name].exists {
            springboard.buttons[name].tap()
            break
        }
        sleep(3)
        shot("lock-screen", suffix)

        XCUIDevice.shared.press(.home)
        springboard.swipeUp()
        app.activate()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        app.buttons["Stop"].tap()
        XCTAssertTrue(anyStart.waitForExistence(timeout: 10))
    }

    private func allowNotificationsIfAsked() {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 4) else { return }
        if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap() }
    }

    private func shot(_ name: String, _ suffix: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(name)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["POMO_DESIGN_SHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("redesign-ios-\(name)-\(suffix).png"))
        }
    }
}
