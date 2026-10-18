import Foundation
import Testing
@testable import PomoLive
import PomoUI

struct NotificationPlannerTests {
    @Test func runningBlockGetsNotificationAtItsAbsoluteEnd() {
        let action = NotificationPlanner.plan(
            timer: timer(.running, remaining: 10 * min1, label: "write"), nowMs: t0, scheduled: nil)
        guard case let .schedule(n) = action else { Issue.record("expected schedule, got \(action)"); return }
        #expect(n.fireAtMs == t0 + 10 * min1)
        #expect(n.blockId == "b1")
        #expect(n.title == "Focus complete")
        #expect(n.body == "write is done. Time for a break.")
    }

    @Test func breaksSayTheBreakIsOver() {
        let short = NotificationPlanner.plan(timer: timer(.running, kind: .shortBreak), nowMs: t0, scheduled: nil)
        let long = NotificationPlanner.plan(timer: timer(.running, kind: .longBreak), nowMs: t0, scheduled: nil)
        guard case let .schedule(s) = short, case let .schedule(l) = long else { Issue.record("no schedule"); return }
        #expect(s.title == "Break over" && l.title == "Long break over")
        #expect(s.body == "Ready for the next focus block.")
    }

    @Test func unchangedTimerKeepsThePendingRequestDespiteMillisecondJitter() {
        let first = NotificationPlanner.plan(timer: timer(.running, remaining: 600_000), nowMs: t0, scheduled: nil)
        guard case let .schedule(n) = first else { Issue.record("no schedule"); return }
        // Same block read 30 s later: remaining dropped by 30 s, end time moved by 3 ms of rounding.
        let later = NotificationPlanner.plan(timer: timer(.running, remaining: 570_003), nowMs: t0 + 30_000, scheduled: n)
        #expect(later == .keep)
    }

    @Test func pauseSkipStopAndIdleCancel() {
        let pending = BlockEndNotification(blockId: "b1", kind: .focus, fireAtMs: t0 + min1, title: "t", body: "b")
        #expect(NotificationPlanner.plan(timer: timer(.paused, remaining: min1), nowMs: t0, scheduled: pending) == .cancel)
        #expect(NotificationPlanner.plan(timer: timer(.idle), nowMs: t0, scheduled: pending) == .cancel)
    }

    @Test func aRunningBlockWithNothingLeftIsNotScheduled() {
        // It ended while nobody looked; the Timer will read idle on the next status.
        #expect(NotificationPlanner.plan(timer: timer(.running, remaining: 0), nowMs: t0, scheduled: nil) == .cancel)
    }

    @Test func extendMovesTheNotification() {
        let first = NotificationPlanner.plan(timer: timer(.running, remaining: 10 * min1), nowMs: t0, scheduled: nil)
        guard case let .schedule(n) = first else { Issue.record("no schedule"); return }
        let extended = NotificationPlanner.plan(
            timer: timer(.running, planned: 30 * min1, remaining: 15 * min1), nowMs: t0 + 1000, scheduled: n)
        guard case let .schedule(m) = extended else { Issue.record("expected reschedule"); return }
        #expect(m.fireAtMs == t0 + 1000 + 15 * min1)
    }

    @Test func aNewBlockOrANewLabelReplacesTheRequest() {
        let first = NotificationPlanner.plan(timer: timer(.running, label: "a"), nowMs: t0, scheduled: nil)
        guard case let .schedule(n) = first else { Issue.record("no schedule"); return }
        #expect(NotificationPlanner.plan(timer: timer(.running, label: "b"), nowMs: t0, scheduled: n) != .keep)
        #expect(NotificationPlanner.plan(timer: timer(.running, label: "a", id: "b2"), nowMs: t0, scheduled: n) != .keep)
    }
}

final class FakeScheduler: NotificationScheduling, @unchecked Sendable {
    enum Call: Equatable { case schedule(BlockEndNotification), cancel }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    func schedule(_ n: BlockEndNotification) async { lock.withLock { recorded.append(.schedule(n)) } }
    func cancel() async { lock.withLock { recorded.append(.cancel) } }
}

struct NotificationCoordinatorTests {
    @Test func followsATimerThroughStartPauseResumeExtendSkip() async {
        let fake = FakeScheduler()
        let c = NotificationCoordinator(scheduler: fake)
        await c.update(timer: timer(.running, remaining: 25 * min1), nowMs: t0)                      // start
        await c.update(timer: timer(.running, remaining: 25 * min1 - 5), nowMs: t0 + 5)               // same block, no change
        await c.update(timer: timer(.paused, remaining: 20 * min1), nowMs: t0 + 5 * min1)             // pause
        await c.update(timer: timer(.paused, remaining: 20 * min1), nowMs: t0 + 6 * min1)             // still paused
        await c.update(timer: timer(.running, remaining: 20 * min1), nowMs: t0 + 7 * min1)            // resume
        await c.update(timer: timer(.running, planned: 30 * min1, remaining: 25 * min1), nowMs: t0 + 7 * min1) // extend
        await c.update(timer: timer(.idle), nowMs: t0 + 8 * min1)                                      // skip
        let calls = fake.calls
        #expect(calls.count == 5)
        guard calls.count == 5 else { return }
        #expect(calls[0] == .schedule(.init(blockId: "b1", kind: .focus, fireAtMs: t0 + 25 * min1, title: "Focus complete", body: "Time for a break.")))
        #expect(calls[1] == .cancel)
        #expect(calls[2] == .schedule(.init(blockId: "b1", kind: .focus, fireAtMs: t0 + 27 * min1, title: "Focus complete", body: "Time for a break.")))
        #expect(calls[3] == .schedule(.init(blockId: "b1", kind: .focus, fireAtMs: t0 + 32 * min1, title: "Focus complete", body: "Time for a break.")))
        #expect(calls[4] == .cancel)
    }

    @Test func aFirstIdleUpdateClearsARequestLeftByAnEarlierLaunch() async {
        let fake = FakeScheduler()
        let c = NotificationCoordinator(scheduler: fake)
        await c.update(timer: timer(.idle), nowMs: t0)
        await c.update(timer: timer(.idle), nowMs: t0 + 1000)
        #expect(fake.calls == [.cancel])
    }

    @Test func aBlockThatEndedOnAnotherDeviceCancelsHere() async {
        let fake = FakeScheduler()
        let c = NotificationCoordinator(scheduler: fake)
        await c.update(timer: timer(.running, remaining: 5 * min1), nowMs: t0)
        await c.update(timer: timer(.idle), nowMs: t0 + min1)  // a synced skip arrived
        #expect(fake.calls.last == .cancel)
        #expect(fake.calls.count == 2)
    }
}
