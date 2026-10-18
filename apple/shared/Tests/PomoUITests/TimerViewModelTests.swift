import Foundation
import Testing
@testable import PomoUI

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

final class FakeAPI: PomoAPI, @unchecked Sendable {
    let statusBox: Box<Status>
    let sentBox = Box<[Command]>([])
    let recentBox = Box<[Block]>([])
    private let contBox = Box<AsyncThrowingStream<StreamEvent, Error>.Continuation?>(nil)
    let streamOpens = Box(0)
    let statusCalls = Box(0)
    let blocksCalls = Box(0)

    init(_ s: Status) { statusBox = Box(s) }

    func status() async throws -> Status { statusCalls.value += 1; return statusBox.value }
    func send(_ command: Command, source: String?) async throws -> CommandResult {
        sentBox.value.append(command)
        return CommandResult(timer: statusBox.value.timer, replayed: false)
    }
    func stats(fromMs: Int64?, toMs: Int64?, tzOffsetMin: Int, groupBy: StatsGroupBy) async throws -> Stats { Stats() }
    func blocks(fromMs: Int64?, toMs: Int64?, limit: Int?) async throws -> [Block] { blocksCalls.value += 1; return recentBox.value }
    func stream() -> AsyncThrowingStream<StreamEvent, Error> {
        let (s, c) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        contBox.value = c
        streamOpens.value += 1
        c.yield(.opened)
        return s
    }
    func emit(_ name: String, _ data: String) { contBox.value?.yield(.message(SSEMessage(event: name, data: data))) }
    func failStream() { contBox.value?.finish(throwing: ConnectionError.unreachable("gone")) }
}

func running(_ remaining: Int64, source: String = "user", label: String? = "write", kind: Kind = .focus, now: Int64 = 1_000_000) -> Status {
    Status(
        nowMs: now,
        timer: TimerState(
            status: .running,
            block: Block(id: "b1", kind: kind, label: label, source: source, plannedMs: 1_500_000),
            remainingMs: remaining, nextKind: .shortBreak),
        today: Today(focusMs: 600_000, completedFocus: 1))
}

let idleStatus = Status(nowMs: 1_000_000, timer: TimerState(status: .idle, nextKind: .focus), today: Today(focusMs: 0, completedFocus: 0))

func waitUntil(_ timeout: Double = 3, _ cond: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await cond()
}

@MainActor
func makeModel(_ api: FakeAPI, clock: Box<Int64> = Box(1_000_000), connector: (@Sendable () async throws -> any PomoAPI)? = nil) -> TimerViewModel {
    let settings = PomoSettings(defaults: UserDefaults(suiteName: "pomo-test-\(UUID().uuidString)")!)
    return TimerViewModel(
        settings: settings,
        connector: connector ?? { api },
        clock: { clock.value },
        sleep: { try await Task.sleep(for: min($0, .milliseconds(20))) },
        runTicker: false,
        resyncInterval: .seconds(3600))
}

@MainActor @Suite struct TimerViewModelTests {
    @Test func countdownTicksLocallyFromEndTime() async {
        let clock = Box<Int64>(1_000_000)
        let api = FakeAPI(running(90_000))
        let m = makeModel(api, clock: clock)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        #expect(m.menuTitle == "01:30")
        #expect(m.glyph == .focus)
        clock.value = 1_045_000
        m.tick()
        #expect(m.menuTitle == "00:45")
        #expect(m.progress > 0.9 && m.progress < 1)
        clock.value = 2_000_000
        m.tick()
        #expect(m.menuTitle == "00:00")
        #expect(m.phaseName == "Completed")
    }

    @Test func idleShowsOnlyGlyph() async {
        let api = FakeAPI(idleStatus)
        let m = makeModel(api)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        #expect(m.menuTitle == "")
        #expect(m.glyph == .idle)
        #expect(m.phaseName == "Ready")
    }

    @Test func eventsResyncAndPhaseTransitions() async {
        let api = FakeAPI(running(60_000))
        let m = makeModel(api)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })

        var paused = running(60_000)
        paused.timer.status = .paused
        api.statusBox.value = paused
        api.emit("pomo.event", "{}")
        #expect(await waitUntil { m.glyph == .paused })
        #expect(m.phaseName == "Paused")
        #expect(m.phaseDetail == "Focus")
        #expect(m.menuTitle == "01:00")

        api.statusBox.value = running(300_000, kind: .shortBreak)
        api.emit("pomo.event", "{}")
        #expect(await waitUntil { m.glyph == .breakTime })
        #expect(m.phaseName == "Short break")

        api.statusBox.value = idleStatus
        api.emit("pomo.event", "{}")
        #expect(await waitUntil { m.glyph == .idle })
    }

    @Test func resyncEventRefetchesStatusAndBlocksLikeAReconnect() async {
        let api = FakeAPI(running(60_000))
        let m = makeModel(api)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online && m.resyncCount == 1 })

        // While the client was behind, the timer ended and a block landed in the history.
        api.statusBox.value = idleStatus
        api.recentBox.value = [Block(id: "b1", kind: .focus, plannedMs: 1, phase: "ended", outcome: "completed", endedMs: 5)]
        let status = api.statusCalls.value, blocks = api.blocksCalls.value
        api.emit("pomo.resync", #"{"missed":12}"#)
        #expect(await waitUntil { m.resyncCount == 2 })
        #expect(api.statusCalls.value > status)
        #expect(api.blocksCalls.value > blocks)
        #expect(m.glyph == .idle)
        #expect(m.lastBlockSummary == "Last: focus completed")
        #expect(m.connection == .online)
        #expect(api.streamOpens.value == 1)  // no reconnect: the stream continues
    }

    @Test func idleReportsLastBlockOutcome() async {
        let api = FakeAPI(idleStatus)
        api.recentBox.value = [Block(id: "x", kind: .focus, plannedMs: 1, phase: "ended", outcome: "completed", endedMs: 5)]
        let m = makeModel(api)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        #expect(m.lastBlockSummary == "Last: focus completed")
        #expect(m.nextKind == .shortBreak)
        #expect(m.effectiveKind == .shortBreak)
    }

    @Test func sourceTagOnlyForAgents() async {
        let api = FakeAPI(running(60_000, source: "agent:claude"))
        let m = makeModel(api)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        #expect(m.sourceTag == "started by claude")
        api.statusBox.value = running(60_000, source: "user")
        api.emit("pomo.event", "{}")
        #expect(await waitUntil { m.sourceTag == nil })
    }

    @Test func blockEndEventNotifiesWithBlockDetails() async {
        let api = FakeAPI(running(1_000, label: "deep work"))
        let m = makeModel(api)
        let got = Box<[BlockEndNotice]>([])
        m.onBlockEnd = { got.value.append($0) }
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        api.statusBox.value = idleStatus
        api.emit("pomo.block_end", #"{"block_id":"b1","outcome":"completed","ended_ms":1001000}"#)
        #expect(await waitUntil { !got.value.isEmpty })
        #expect(got.value == [BlockEndNotice(kind: .focus, label: "deep work")])
        #expect(await waitUntil { m.glyph == .idle })
    }

    @Test func unreachableDaemonShowsOfflineThenRecovers() async {
        struct Down: Error, LocalizedError { var errorDescription: String? { "daemon down" } }
        let api = FakeAPI(idleStatus)
        let up = Box(false)
        let m = makeModel(api, connector: { if up.value { return api }; throw Down() })
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .offline("daemon down") })
        #expect(m.glyph == .offline)
        #expect(m.menuTitle == "")
        up.value = true
        m.retry()
        #expect(await waitUntil { m.connection == .online })
    }

    @Test func streamDropGoesOfflineAndReconnects() async {
        let api = FakeAPI(running(60_000))
        let m = makeModel(api)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        let opens = api.streamOpens.value
        api.failStream()
        #expect(await waitUntil { api.streamOpens.value > opens && m.connection == .online })
    }

    @Test func startUsesSettingsDurationsAndLabel() async {
        let api = FakeAPI(idleStatus)
        let m = makeModel(api)
        m.settings.focusMinutes = 50
        m.settings.shortBreakMinutes = 7
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        let asked = Box(0)
        m.onWillStart = { asked.value += 1 }
        m.labelDraft = "essay"
        await m.start()
        #expect(api.sentBox.value == [.start(kind: .focus, plannedMs: 50 * 60_000, label: "essay", project: nil)])
        #expect(asked.value == 1)
        m.kindOverride = .shortBreak
        await m.start()
        #expect(api.sentBox.value.last == .start(kind: .shortBreak, plannedMs: 7 * 60_000, label: "essay", project: nil))
    }

    @Test func idleStartFollowsNextKind() async {
        var s = idleStatus
        s.timer.nextKind = .longBreak
        let api = FakeAPI(s)
        let m = makeModel(api)
        m.settings.longBreakMinutes = 20
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        await m.start()
        #expect(api.sentBox.value == [.start(kind: .longBreak, plannedMs: 20 * 60_000, label: "", project: nil)])
    }

    @Test func controlsSendMatchingCommands() async {
        let api = FakeAPI(running(60_000))
        let m = makeModel(api)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.connection == .online })
        await m.togglePause()
        await m.extend()
        await m.skip()
        await m.reset()
        await m.stop()
        m.labelDraft = "renamed"
        await m.commitLabel()
        #expect(api.sentBox.value == [.pause, .extend(addMs: 300_000), .skip, .reset, .stop, .label(blockId: "b1", label: "renamed")])
    }

    @Test func labelDraftFollowsBlockChange() async {
        let api = FakeAPI(running(60_000, label: "first"))
        let m = makeModel(api)
        m.connect(); defer { m.disconnect() }
        #expect(await waitUntil { m.labelDraft == "first" })
    }

    @Test func backoffGrowsAndCaps() {
        #expect(Backoff.delay(attempt: 0) == .milliseconds(500))
        #expect(Backoff.delay(attempt: 3) == .seconds(4))
        #expect(Backoff.delay(attempt: 99) == .seconds(30))
    }
}

@MainActor @Suite struct SettingsTests {
    @Test func defaultsAndPersistence() {
        let suite = "pomo-settings-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let s = PomoSettings(defaults: d)
        let got: [Int] = [s.focusMinutes, s.shortBreakMinutes, s.longBreakMinutes, s.longBreakEvery]
        #expect(got == [25, 5, 15, 4])
        #expect(s.showDockIcon == false)
        s.focusMinutes = 30; s.showDockIcon = true
        let again = PomoSettings(defaults: d)
        #expect(again.focusMinutes == 30 && again.showDockIcon)
        #expect(again.plannedMs(for: .focus) == 30 * 60_000)
    }
}
