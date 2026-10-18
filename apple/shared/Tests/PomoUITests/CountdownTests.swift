import Testing
@testable import PomoUI

@Suite struct CountdownTests {
    private func running(remaining: Int64, planned: Int64 = 1_500_000, now: Int64 = 1_000_000, kind: Kind = .focus) -> Countdown {
        let b = Block(id: "b", kind: kind, plannedMs: planned)
        return Countdown(timer: TimerState(status: .running, block: b, remainingMs: remaining, nextKind: .shortBreak), nowMs: now)
    }

    @Test func runningDerivesFromAbsoluteEnd() {
        let c = running(remaining: 90_000)
        #expect(c.endsMs == 1_090_000)
        #expect(c.display(at: 1_000_000) == "01:30")
        #expect(c.display(at: 1_030_000) == "01:00")
        // A late clock read (app was asleep) never goes negative.
        #expect(c.remainingMs(at: 5_000_000) == 0)
        #expect(c.display(at: 5_000_000) == "00:00")
    }

    @Test func displayRoundsUp() {
        let c = running(remaining: 59_001)
        #expect(c.display(at: 1_000_000) == "01:00")
        #expect(c.display(at: 1_000_001) == "00:59")
        #expect(c.display(at: 1_000_999) == "00:59")
    }

    @Test func pausedFreezes() {
        let b = Block(id: "b", kind: .focus, plannedMs: 1_500_000, phase: "paused")
        let c = Countdown(timer: TimerState(status: .paused, block: b, remainingMs: 600_000), nowMs: 1)
        #expect(c.endsMs == nil)
        #expect(c.display(at: 1) == "10:00")
        #expect(c.display(at: 9_999_999) == "10:00")
        #expect(c.msUntilNextTick(at: 1) == nil)
    }

    @Test func idleHasNothing() {
        let c = Countdown(timer: TimerState(status: .idle, remainingMs: nil, nextKind: .focus), nowMs: 1)
        #expect(c == .idle)
        #expect(c.progress(at: 1) == 0)
    }

    @Test func progressAndTicks() {
        let c = running(remaining: 750_000)
        #expect(c.progress(at: 1_000_000) == 0.5)
        #expect(c.msUntilNextTick(at: 1_000_000) == 1000)
        #expect(c.msUntilNextTick(at: 1_000_250) == 750)
        #expect(running(remaining: 0).msUntilNextTick(at: 1_000_000) == nil)
    }

    @Test func formatsLongBlocksPast99Minutes() {
        #expect(Countdown.format(remainingMs: 6_000_000) == "100:00")
    }

    @Test func sourceTags() {
        #expect(sourceTag("user") == nil)
        #expect(sourceTag("agent:claude") == "started by claude")
    }

    @Test func durations() {
        #expect(formatDuration(ms: 25 * 60_000) == "25 min")
        #expect(formatDuration(ms: 90 * 60_000) == "1 h 30 min")
        #expect(formatDuration(ms: 120 * 60_000) == "2 h")
    }
}
