import Foundation
import PomoCoreFFI
import PomoUI

/// The Core and Sync node running inside this process, with the PomoUI API on top.
public final class PomoEngine: Sendable {
    public let core: PomoCore
    let hub = EventHub()
    public let api: CorePomoAPI

    /// Takes over the Core's listener.
    public init(core: PomoCore, tzOffsetMin: @escaping @Sendable () -> Int = { TimeZone.current.secondsFromGMT() / 60 }) {
        self.core = core
        self.api = CorePomoAPI(core: core, hub: hub, tzOffsetMin: tzOffsetMin)
        core.setListener(listener: hub)
    }

    /// Opens (creating when absent) the store and device key in `directory` and starts the Sync node.
    /// `network` is `.n0` for the real relays, `.local` for loopback only (tests).
    public static func open(directory: URL, deviceName: String, network: CoreNetwork = .n0) async throws -> PomoEngine {
        let path = directory.path
        let core = try await Task.detached {
            do { return try PomoCore.open(dir: path, deviceName: deviceName, network: network) } catch { throw apiError(error) }
        }.value
        return PomoEngine(core: core)
    }

    public var deviceId: String { core.deviceId() }

    /// Foreground means live: peers keep sessions open and new events flow both ways.
    public func setLive(_ live: Bool) { core.setLive(live: live) }

    public func shutdown() { core.shutdown() }
}

extension CorePomoAPI: SyncRunning {
    public func syncNow() async throws -> [PeerSync] {
        do { return try await core.syncNow().map(PeerSync.init) } catch { throw apiError(error) }
    }

    public func syncIdle() async throws -> [PeerSync] {
        do { return try await core.syncIdle().map(PeerSync.init) } catch { throw apiError(error) }
    }

    public func setLive(_ live: Bool) { core.setLive(live: live) }
}
