import Foundation
import Testing
@testable import PomoLive
import PomoUI

struct LiveActivityTests {
    @Test func runningBlockMapsToAbsoluteTimes() throws {
        let c = try #require(LiveActivityPlanner.content(
            timer: timer(.running, planned: 25 * min1, remaining: 10 * min1, label: "write"), nowMs: t0))
        #expect(c.endsMs == t0 + 10 * min1)
        #expect(c.startMs == t0 + 10 * min1 - 25 * min1)
        #expect(!c.paused && c.label == "write" && c.phaseName == "Focus")
        #expect(c.progress(at: t0) == 15.0 / 25.0)
        #expect(c.progress(at: t0 + 10 * min1) == 1)
        #expect(c.staleDate == c.endDate)
        #expect(c.interval.lowerBound < c.interval.upperBound)
    }

    @Test func extendedBlockKeepsTheRingFractionHonest() throws {
        // 25 min block, 20 min elapsed, extended by 5: 10 left of 30.
        let c = try #require(LiveActivityPlanner.content(
            timer: timer(.running, planned: 30 * min1, remaining: 10 * min1), nowMs: t0))
        #expect(abs(c.progress(at: t0) - 20.0 / 30.0) < 1e-9)
    }

    @Test func pausedBlockFreezesTheCountdown() throws {
        let c = try #require(LiveActivityPlanner.content(
            timer: timer(.paused, kind: .shortBreak, planned: 5 * min1, remaining: 3 * min1 + 5_000), nowMs: t0))
        #expect(c.paused && c.phaseName == "Paused")
        #expect(c.frozenDisplay == "03:05")
        #expect(c.staleDate == nil)
        #expect(abs(c.progress(at: t0 + 10 * min1) - (1 - 185_000.0 / 300_000.0)) < 1e-9, "paused progress ignores the clock")
    }

    @Test func idleFinishedAndEmptyLabelsHaveNoContentOrNoLabel() {
        #expect(LiveActivityPlanner.content(timer: timer(.idle), nowMs: t0) == nil)
        #expect(LiveActivityPlanner.content(timer: timer(.running, remaining: 0), nowMs: t0) == nil)
        let c = LiveActivityPlanner.content(timer: timer(.running, label: ""), nowMs: t0)
        #expect(c?.label == nil)
    }

    @Test func planStartsUpdatesAndEnds() throws {
        let running = timer(.running, remaining: 10 * min1, label: "a")
        guard case let .start(c) = LiveActivityPlanner.plan(timer: running, nowMs: t0, current: nil) else {
            Issue.record("expected start"); return
        }
        // Same state read again a little later: nothing to do.
        #expect(LiveActivityPlanner.plan(timer: timer(.running, remaining: 10 * min1 - 2_000 + 2, label: "a"), nowMs: t0 + 2_000, current: c) == .none)
        // Pause, label change, extend and a new block each update the same activity.
        for next in [
            timer(.paused, remaining: 9 * min1, label: "a"),
            timer(.running, remaining: 10 * min1, label: "b"),
            timer(.running, planned: 30 * min1, remaining: 15 * min1, label: "a"),
            timer(.running, remaining: 10 * min1, label: "a", id: "b2"),
        ] {
            guard case .update = LiveActivityPlanner.plan(timer: next, nowMs: t0, current: c) else {
                Issue.record("expected update for \(next)"); continue
            }
        }
        #expect(LiveActivityPlanner.plan(timer: timer(.idle), nowMs: t0, current: c) == .end)
        #expect(LiveActivityPlanner.plan(timer: timer(.idle), nowMs: t0, current: nil) == .none)
    }

    @Test func contentSurvivesCodingForActivityKit() throws {
        let c = try #require(LiveActivityPlanner.content(timer: timer(.running, label: "x"), nowMs: t0))
        let back = try JSONDecoder().decode(LiveActivityContent.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}

struct TodaySnapshotTests {
    @Test func buildsFromStatusAndExpiresAtMidnight() {
        // 2027-01-15 12:00 UTC, UTC+1 -> local day 2027-01-15 00:00 local = 2027-01-14 23:00 UTC.
        let now: Int64 = 1_799_841_600_000
        let s = Status(nowMs: now, timer: timer(.idle), today: Today(focusMs: 50 * min1, completedFocus: 2))
        let snap = TodaySnapshot(status: s, tzOffsetMin: 60)
        #expect(snap.dayStartMs == now - 13 * 60 * min1)
        #expect(snap.dayEndMs - snap.dayStartMs == 86_400_000)
        #expect(snap.focusMs(at: now) == 50 * min1)
        #expect(snap.completedFocus(at: now) == 2)
        #expect(snap.focusMs(at: snap.dayEndMs - 1) == 50 * min1)
        #expect(snap.focusMs(at: snap.dayEndMs) == 0, "the next day starts from zero until the app writes again")
        #expect(snap.nextDayStart(after: now) == Date(timeIntervalSince1970: Double(snap.dayEndMs) / 1000))
        #expect(snap.nextDayStart(after: snap.dayEndMs) == nil)
    }

    @Test func storeRoundTripsAndDefaultsToEmpty() throws {
        let suite = "pomo.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SnapshotStore(defaults: defaults)
        #expect(store.load() == .empty)
        let snap = TodaySnapshot(dayStartMs: 1, dayEndMs: 2, focusMs: 3, completedFocus: 4, updatedMs: 5)
        store.save(snap)
        #expect(store.load() == snap)
        #expect(TodaySnapshot.empty.focusMs(at: 0) == 0)
    }
}
