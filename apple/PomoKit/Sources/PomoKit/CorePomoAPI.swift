import Foundation
import PomoCoreFFI
import PomoUI

/// PomoUI's API protocols over the in-process Core instead of the Daemon's HTTP API. The view-models
/// use it unchanged. Core calls are local SQLite reads and writes; only pairing and sync wait on the network.
public struct CorePomoAPI: PomoAPI, DevicesAPI {
    let core: PomoCore
    let hub: EventHub
    let tzOffsetMin: @Sendable () -> Int

    init(core: PomoCore, hub: EventHub, tzOffsetMin: @escaping @Sendable () -> Int) {
        self.core = core; self.hub = hub; self.tzOffsetMin = tzOffsetMin
    }

    // MARK: PomoAPI

    public func status() async throws -> Status {
        try wrap { Status(try core.status(tzOffsetMin: Int32(tzOffsetMin()))) }
    }

    public func send(_ command: Command, source: String?) async throws -> CommandResult {
        try wrap {
            let r = try core.send(command: command.core, source: source, commandKey: nil)
            return CommandResult(timer: TimerState(r.timer), replayed: r.replayed)
        }
    }

    public func stats(fromMs: Int64?, toMs: Int64?, tzOffsetMin: Int, groupBy: StatsGroupBy) async throws -> Stats {
        try wrap {
            let g: CoreGroupBy = switch groupBy {
            case .day: .day
            case .label: .label
            case .project: .project
            }
            return Stats(try core.stats(fromMs: fromMs, toMs: toMs, tzOffsetMin: Int32(tzOffsetMin), groupBy: g))
        }
    }

    public func blocks(fromMs: Int64?, toMs: Int64?, limit: Int?) async throws -> [Block] {
        try wrap {
            try core.blocks(fromMs: fromMs, toMs: toMs, kind: nil, limit: limit.map { UInt32(max(1, $0)) }).map(Block.init)
        }
    }

    /// `opened` first, then `pomo.event` for every event stored on this Device (local or synced) and
    /// `pomo.block_end` when the running block reaches its end time, as the Daemon's `/v1/stream` does.
    public func stream() -> AsyncThrowingStream<StreamEvent, Error> {
        let core = self.core, hub = self.hub
        return AsyncThrowingStream { continuation in
            let watcher = BlockEndWatcher(core: core) { continuation.yield(.message($0)) }
            let token = hub.subscribe { event in
                continuation.yield(.message(SSEMessage(event: "pomo.event", data: event.json)))
                watcher.rearm()
            }
            continuation.yield(.opened)
            watcher.rearm()
            continuation.onTermination = { _ in
                hub.unsubscribe(token)
                watcher.cancel()
            }
        }
    }

    // MARK: DevicesAPI

    public func devices() async throws -> DevicesList {
        try wrap {
            let d = try core.devices()
            return DevicesList(deviceId: d.deviceId, name: d.name, devices: d.devices.map(DeviceInfo.init))
        }
    }

    public func pairOffer() async throws -> PairOffer {
        do {
            let t = try await core.offerPairing()
            return PairOffer(ticket: t.ticket, expiresMs: t.expiresMs)
        } catch { throw apiError(error) }
    }

    /// `name` is ignored: the Device name is fixed when the Core is opened.
    public func pairJoin(ticket: String, name: String?) async throws -> DeviceInfo {
        do { return DeviceInfo(try await core.join(ticket: ticket)) } catch { throw apiError(error) }
    }

    /// Syncs with every paired Device (the Core has no per-Device round); `deviceId` filters the report.
    public func sync(deviceId: String?) async throws -> [PeerSync] {
        do {
            let all = try await core.syncNow().map(PeerSync.init)
            return deviceId.map { id in all.filter { $0.deviceId == id } } ?? all
        } catch { throw apiError(error) }
    }

    public func revoke(deviceId: String) async throws -> DeviceInfo {
        try wrap { DeviceInfo(try core.revoke(deviceId: deviceId)) }
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw apiError(error) }
    }
}
