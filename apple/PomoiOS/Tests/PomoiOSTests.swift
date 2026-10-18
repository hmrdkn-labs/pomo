import Foundation
import PomoLive
import PomoUI
import UserNotifications
import XCTest
@testable import Pomo

final class NotificationRequestTests: XCTestCase {
    private func note(fireAt ms: Int64) -> BlockEndNotification {
        BlockEndNotification(blockId: "b1", kind: .focus, fireAtMs: ms, title: "Focus complete", body: "Time for a break.")
    }

    func testRequestFiresAtTheAbsoluteEndTime() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r = SystemNotificationScheduler.request(for: note(fireAt: 1_800_000_000_000 + 600_000), now: now)
        let trigger = try XCTUnwrap(r.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 600, accuracy: 0.001)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(r.identifier, BlockEndNotification.identifier)
        XCTAssertEqual(r.content.title, "Focus complete")
        XCTAssertEqual(r.content.userInfo["block_id"] as? String, "b1")
    }

    func testAPastEndTimeFiresInOneSecond() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r = SystemNotificationScheduler.request(for: note(fireAt: 1_799_999_000_000), now: now)
        XCTAssertEqual((r.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 1)
    }
}

final class ScanGateTests: XCTestCase {
    private func ticket() -> String {
        let json = #"{"ticket":"endpoint","secret":"s","name":"mac"}"#
        let b64 = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "pomo-pair:" + b64
    }

    func testOnlyPairingTicketsPassAndRepeatsAreSuppressed() {
        var gate = ScanGate()
        let t0 = Date(timeIntervalSince1970: 100)
        XCTAssertNil(gate.accept("https://example.com", now: t0))
        XCTAssertEqual(gate.accept(ticket(), now: t0), ticket())
        XCTAssertNil(gate.accept(ticket(), now: t0.addingTimeInterval(1)))
        XCTAssertEqual(gate.accept(ticket(), now: t0.addingTimeInterval(4)), ticket())
    }
}

@MainActor
final class SnapshotWriterTests: XCTestCase {
    func testWritesOnlyWhenTheTotalsChange() throws {
        let suite = "pomo.ios.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reloads = 0
        let writer = SnapshotWriter(store: SnapshotStore(defaults: defaults), tzOffsetMin: { 0 }, reload: { reloads += 1 })
        func status(now: Int64, focus: Int64) -> Status {
            Status(nowMs: now, timer: TimerState(status: .idle), today: Today(focusMs: focus, completedFocus: 1))
        }
        writer.write(status: status(now: 1_800_000_000_000, focus: 60_000))
        writer.write(status: status(now: 1_800_000_030_000, focus: 60_000))  // same totals, later clock
        XCTAssertEqual(reloads, 1)
        writer.write(status: status(now: 1_800_000_060_000, focus: 120_000))
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(SnapshotStore(defaults: defaults).load().focusMs, 120_000)
    }
}
