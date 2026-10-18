import Foundation
import Testing
import PomoCoreFFI
import PomoUI
@testable import PomoKit

struct CorePomoAPITests {
    @Test func commandsDriveTheTimerThroughTheRealCore() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let engine = try await makeEngine("phone", in: dir)
        let api = engine.api

        let idle = try await api.status()
        #expect(idle.timer.status == .idle)

        let running = try await api.start(minutes: 25, label: "write")
        #expect(running.status == .running)
        #expect(running.block?.label == "write" && running.block?.kind == .focus && running.block?.source == "user")
        #expect(running.block?.deviceId == engine.deviceId)
        #expect((running.remainingMs ?? 0) > 24 * 60_000)

        #expect(try await api.send(.pause, source: nil).timer.status == .paused)
        #expect(try await api.send(.resume, source: nil).timer.status == .running)
        let extended = try await api.send(.extend(addMs: 5 * 60_000), source: nil).timer
        #expect(extended.block?.plannedMs == ms(30))
        #expect(try await api.send(.reset, source: nil).timer.block?.plannedMs == ms(25))
        _ = try await api.send(.label(blockId: nil, label: "review"), source: "agent:claude")
        #expect(try await api.status().timer.block?.label == "review")
        let skipped = try await api.send(.skip, source: nil).timer
        #expect(skipped.status == .idle && skipped.block == nil)

        let blocks = try await api.blocks(fromMs: nil, toMs: nil, limit: 10)
        #expect(blocks.count == 1)
        #expect(blocks.first?.outcome == "skipped" && blocks.first?.phase == "ended" && blocks.first?.label == "review")
    }

    @Test func invalidCommandsSurfaceAsTheDaemonsApiErrors() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let api = try await makeEngine("phone", in: dir).api
        do {
            _ = try await api.send(.pause, source: nil)
            Issue.record("pause on an idle timer must fail")
        } catch let e as APIError {
            #expect(e.status == 409 && e.code == "invalid_state")
        }
        do {
            _ = try await api.send(.start(kind: .focus, plannedMs: 0, label: nil, project: nil), source: nil)
            Issue.record("a zero duration must fail")
        } catch let e as APIError {
            #expect(e.status == 400)
        }
        do {
            _ = try await api.pairJoin(ticket: "nonsense", name: nil)
            Issue.record("a bad ticket must fail")
        } catch let e as APIError {
            #expect(e.code == "bad_ticket")
            #expect(DevicesProblem.map(e) == .failed("That ticket is not valid. Copy it again from the other device."))
        }
    }

    @Test func statsGroupFocusTimeLikeTheDaemon() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let api = try await makeEngine("phone", in: dir).api
        for label in ["a", "a", "b"] {
            _ = try await api.start(label: label)
            _ = try await api.send(.skip, source: nil)
        }
        let tz = TimeZone.current.secondsFromGMT() / 60
        let (from, to) = StatsRange.lastDays(7, nowMs: PomoUI.nowMs(), tzOffsetMin: tz)
        let byLabel = try await api.stats(fromMs: from, toMs: to, tzOffsetMin: tz, groupBy: .label)
        #expect(Set(byLabel.groups.map(\.key)) == ["a", "b"])
        let byDay = try await api.stats(fromMs: from, toMs: to, tzOffsetMin: tz, groupBy: .day)
        #expect(byDay.groups.count == 1)
        #expect(byDay.tzOffsetMin == tz)
    }

    @Test func streamReportsOpenedThenEveryEventAndTheBlockEnd() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let api = try await makeEngine("phone", in: dir).api
        let seen = Collector<String>()
        let reader = Task {
            for try await e in api.stream() {
                switch e {
                case .opened: seen.add("opened")
                case let .message(m): seen.add(m.event)
                }
            }
        }
        defer { reader.cancel() }
        #expect(await eventually { seen.all == ["opened"] })

        // A 400 ms block: started event, then the block ends by itself.
        _ = try await api.send(.start(kind: .focus, plannedMs: 400, label: nil, project: nil), source: nil)
        #expect(await eventually { seen.all == ["opened", "pomo.event", "pomo.block_end"] })
        let status = try await api.status()
        #expect(status.timer.status == .idle, "a block that ran out reads as completed, not as a negative timer")
        #expect(try await api.blocks(fromMs: nil, toMs: nil, limit: nil).first?.outcome == "completed")
    }

    @Test func aPausedOrExtendedBlockDoesNotEndOnTheOldSchedule() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let api = try await makeEngine("phone", in: dir).api
        let seen = Collector<String>()
        let reader = Task { for try await e in api.stream() { if case let .message(m) = e { seen.add(m.event) } } }
        defer { reader.cancel() }
        _ = try await api.send(.start(kind: .focus, plannedMs: 500, label: nil, project: nil), source: nil)
        _ = try await api.send(.pause, source: nil)
        try await Task.sleep(for: .milliseconds(900))
        #expect(!seen.all.contains("pomo.block_end"))
        #expect(try await api.status().timer.status == .paused)
    }

    @Test func eventJSONMatchesTheDaemonEnvelope() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let api = try await makeEngine("phone", in: dir).api
        let got = Collector<String>()
        let reader = Task { for try await e in api.stream() { if case let .message(m) = e, m.event == "pomo.event" { got.add(m.data) } } }
        defer { reader.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await api.start(label: "x")
        #expect(await eventually { !got.all.isEmpty })
        let text = try #require(got.all.first)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(obj["type"] as? String == "timer.started")
        #expect(obj["seq"] as? Int == 1)
        #expect(obj["source"] as? String == "user")
        #expect((obj["payload"] as? [String: Any])?["label"] as? String == "x")
        #expect(obj["command_key"] is String)
    }

    @MainActor @Test func theSharedTimerViewModelRunsOnTheCore() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let api = try await makeEngine("phone", in: dir).api
        let suite = "pomo.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = TimerViewModel(settings: PomoSettings(defaults: defaults), connector: { api })
        vm.connect()
        defer { vm.disconnect() }
        #expect(await eventuallyOnMain { vm.isOnline })
        #expect(vm.countdown.status == .idle)

        vm.labelDraft = "deep work"
        await vm.start()
        #expect(vm.countdown.status == .running && vm.block?.label == "deep work")
        #expect(vm.display == "25:00" || vm.display == "24:59")
        await vm.pause()
        #expect(vm.countdown.status == .paused && vm.phaseName == "Paused")
        await vm.resume()
        await vm.extend(minutes: 5)
        #expect(vm.block?.plannedMs == ms(30))
        await vm.skip()
        #expect(vm.countdown.status == .idle)
        #expect(vm.lastBlockSummary == "Last: focus skipped")
        #expect(vm.today.completedFocus == 0)
    }
}
