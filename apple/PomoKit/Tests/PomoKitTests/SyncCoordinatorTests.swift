import Foundation
import Testing
import PomoUI
@testable import PomoKit

final class FakeRunner: SyncRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var failWith: Error?
    var results: [PeerSync] = [PeerSync(deviceId: "mac", sent: 1, received: 2)]
    var gate: AsyncStream<Void>?
    var calls: [String] { lock.withLock { log } }
    private func note(_ s: String) { lock.withLock { log.append(s) } }

    func syncNow() async throws -> [PeerSync] { note("now"); if let gate { for await _ in gate { break } }; if let failWith { throw failWith }; return results }
    func syncIdle() async throws -> [PeerSync] { note("idle"); if let failWith { throw failWith }; return results }
    func setLive(_ live: Bool) { note(live ? "live" : "background") }
}

/// A sleep the test releases by hand.
final class Ticker: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let cont: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var requested: [Duration] = []
    init() { (stream, cont) = AsyncStream<Void>.makeStream() }
    var requests: [Duration] { lock.withLock { requested } }
    func sleep(_ d: Duration) async throws {
        lock.withLock { requested.append(d) }
        for await _ in stream { return }
        throw CancellationError()
    }
    func fire() { cont.yield() }
}

@MainActor
struct SyncCoordinatorTests {
    @Test func syncsOnOpenThenEverySixtySecondsWhileForegrounded() async {
        let runner = FakeRunner(), ticker = Ticker()
        let c = SyncCoordinator(runner: runner, clock: { 42 }, sleep: ticker.sleep)
        c.foregrounded()
        #expect(await eventuallyOnMain { runner.calls == ["live", "now"] && c.lastSyncMs == 42 })
        #expect(c.lastResults == [PeerSync(deviceId: "mac", sent: 1, received: 2)] && c.lastError == nil)
        #expect(await eventuallyOnMain { ticker.requests == [.seconds(60)] })
        ticker.fire()
        #expect(await eventuallyOnMain { runner.calls == ["live", "now", "idle"] })
        ticker.fire()
        #expect(await eventuallyOnMain { runner.calls == ["live", "now", "idle", "idle"] })
    }

    @Test func backgroundStopsTheRoundsAndTheLiveFlag() async {
        let runner = FakeRunner(), ticker = Ticker()
        let c = SyncCoordinator(runner: runner, sleep: ticker.sleep)
        c.foregrounded()
        #expect(await eventuallyOnMain { ticker.requests.count == 1 })
        c.backgrounded()
        #expect(runner.calls == ["live", "now", "background"])
        ticker.fire()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(runner.calls == ["live", "now", "background"], "no rounds after backgrounding")
        // Returning to the foreground syncs again right away.
        c.foregrounded()
        #expect(await eventuallyOnMain { runner.calls.suffix(2) == ["live", "now"] })
    }

    @Test func repeatedForegroundCallsDoNotStackLoops() async {
        let runner = FakeRunner(), ticker = Ticker()
        let c = SyncCoordinator(runner: runner, sleep: ticker.sleep)
        c.foregrounded(); c.foregrounded(); c.foregrounded()
        #expect(await eventuallyOnMain { runner.calls == ["live", "now"] })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(runner.calls == ["live", "now"])
    }

    @Test func aFailedRoundIsReportedAndTheNextOneStillRuns() async {
        let runner = FakeRunner(), ticker = Ticker()
        runner.failWith = APIError(status: 500, code: "sync_failed", message: "network down")
        let c = SyncCoordinator(runner: runner, sleep: ticker.sleep)
        c.foregrounded()
        #expect(await eventuallyOnMain { c.lastError == "network down" })
        runner.failWith = nil
        ticker.fire()
        #expect(await eventuallyOnMain { c.lastError == nil && runner.calls.last == "idle" })
    }

    @Test func aPeerErrorInTheResultsIsSurfaced() async {
        let runner = FakeRunner()
        runner.results = [PeerSync(deviceId: "mac", error: "timeout waiting for connect")]
        let c = SyncCoordinator(runner: runner)
        await c.syncNow()
        #expect(c.lastError == "timeout waiting for connect")
    }

    @Test func syncNowDoesNothingWhileARoundIsRunning() async {
        let runner = FakeRunner()
        let (gate, release) = AsyncStream<Void>.makeStream()
        runner.gate = gate
        let c = SyncCoordinator(runner: runner)
        let first = Task { await c.syncNow() }
        #expect(await eventuallyOnMain { c.isSyncing })
        await c.syncNow()
        #expect(runner.calls == ["now"])
        release.yield()
        await first.value
        #expect(!c.isSyncing)
    }
}
