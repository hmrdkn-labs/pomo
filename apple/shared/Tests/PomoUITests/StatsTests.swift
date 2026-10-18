import Foundation
import Testing
@testable import PomoUI

@Suite struct StatsRangeTests {
    @Test func dayStartRespectsOffset() {
        // 2026-01-02T01:00:00Z with UTC+2 is 03:00 local on Jan 2; local midnight is Jan 1 22:00Z.
        let now: Int64 = 1_767_315_600_000
        let start = StatsRange.dayStart(nowMs: now, tzOffsetMin: 120)
        #expect((start + 120 * 60_000) % StatsRange.dayMs == 0)
        #expect(start <= now && now < start + StatsRange.dayMs)
        #expect(StatsRange.dayKey(dayStartMs: start, tzOffsetMin: 120) == "2026-01-02")
    }

    @Test func negativeOffsetAndWindow() {
        let now: Int64 = 1_767_315_600_000  // 2026-01-02T01:00Z = Jan 1 20:00 at UTC-5
        let (from, to) = StatsRange.lastDays(7, nowMs: now, tzOffsetMin: -300)
        #expect(to - from == 7 * StatsRange.dayMs)
        #expect(StatsRange.dayKey(dayStartMs: to - StatsRange.dayMs, tzOffsetMin: -300) == "2026-01-01")
        #expect(StatsRange.dayKey(dayStartMs: from, tzOffsetMin: -300) == "2025-12-26")
    }
}

@MainActor @Suite struct StatsViewModelTests {
    @Test func buildsSevenDaysFillingGapsAndRanksLabels() async {
        let now: Int64 = 1_767_315_600_000
        let tz = 0
        let (from, to) = StatsRange.lastDays(7, nowMs: now, tzOffsetMin: tz)
        let todayKey = StatsRange.dayKey(dayStartMs: to - StatsRange.dayMs, tzOffsetMin: tz)
        let api = StatsAPI(
            day: Stats(focusMs: 300, completedFocus: 2, streakDays: 3, groups: [StatGroup(key: todayKey, focusMs: 200, completedFocus: 1), StatGroup(key: "2026-01-01", focusMs: 100, completedFocus: 1)]),
            label: Stats(focusMs: 300, groups: [StatGroup(key: "", focusMs: 50, completedFocus: 1), StatGroup(key: "deep", focusMs: 250, completedFocus: 1), StatGroup(key: "zero", focusMs: 0, completedFocus: 0)]),
            project: Stats())
        let vm = StatsViewModel(connector: { api }, clock: { now }, tzOffsetMin: { tz })
        await vm.load()
        #expect(vm.error == nil)
        #expect(vm.days.count == 7)
        #expect(vm.days.last?.key == todayKey && vm.todayFocusMs == 200)
        #expect(vm.days.first?.focusMs == 0)
        #expect(vm.days.map(\.focusMs).reduce(0, +) == 300)
        #expect(vm.weekFocusMs == 300 && vm.streakDays == 3)
        #expect(vm.labels.map(\.key) == ["deep", ""])
        #expect(api.queries.value.allSatisfy { $0.from == from && $0.to == to })
    }

    @Test func errorsSurface() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let vm = StatsViewModel(connector: { throw Boom() })
        await vm.load()
        #expect(vm.error == "boom")
    }
}

final class StatsAPI: PomoAPI, @unchecked Sendable {
    struct Q: Sendable { var from: Int64?; var to: Int64?; var by: StatsGroupBy }
    let queries = Box<[Q]>([])
    let day: Stats, label: Stats, project: Stats
    init(day: Stats, label: Stats, project: Stats) { self.day = day; self.label = label; self.project = project }
    func status() async throws -> Status { fatalError() }
    func send(_ command: Command, source: String?) async throws -> CommandResult { fatalError() }
    func stats(fromMs: Int64?, toMs: Int64?, tzOffsetMin: Int, groupBy: StatsGroupBy) async throws -> Stats {
        queries.value.append(Q(from: fromMs, to: toMs, by: groupBy))
        switch groupBy { case .day: return day; case .label: return label; case .project: return project }
    }
    func blocks(fromMs: Int64?, toMs: Int64?, limit: Int?) async throws -> [Block] { [] }
    func stream() -> AsyncThrowingStream<StreamEvent, Error> { fatalError() }
}

@Suite struct CadenceTests {
    private func b(_ kind: Kind, _ outcome: String) -> Block {
        Block(id: UUID().uuidString, kind: kind, plannedMs: 1, phase: "ended", outcome: outcome)
    }

    @Test func longBreakAfterEveryNthCompletedFocus() {
        let recent = [b(.focus, "completed"), b(.shortBreak, "completed"), b(.focus, "completed"), b(.focus, "completed")]
        #expect(Cadence.nextKind(recent: recent, every: 3, fallback: .focus) == .longBreak)
        #expect(Cadence.nextKind(recent: recent, every: 4, fallback: .focus) == .shortBreak)
    }

    @Test func countingStopsAtMostRecentLongBreakAndIgnoresSkipped() {
        let recent = [b(.focus, "completed"), b(.focus, "skipped"), b(.longBreak, "skipped"), b(.focus, "completed"), b(.focus, "completed")]
        #expect(Cadence.nextKind(recent: recent, every: 2, fallback: .focus) == .shortBreak)
        #expect(Cadence.nextKind(recent: recent, every: 1, fallback: .focus) == .longBreak)
    }

    @Test func otherwiseDaemonSuggestionStands() {
        #expect(Cadence.nextKind(recent: [], every: 4, fallback: .focus) == .focus)
        #expect(Cadence.nextKind(recent: [b(.shortBreak, "completed")], every: 4, fallback: .focus) == .focus)
        #expect(Cadence.nextKind(recent: [b(.focus, "abandoned")], every: 4, fallback: .focus) == .focus)
    }
}
