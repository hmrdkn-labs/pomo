import Foundation
import PomoCoreFFI
import PomoUI
@testable import PomoKit

struct TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("pomokit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// A real Core in a temp dir on the loopback network.
func makeEngine(_ name: String, in dir: TempDir) async throws -> PomoEngine {
    try await PomoEngine.open(directory: dir.url.appendingPathComponent(name), deviceName: name, network: .local)
}

func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

extension CorePomoAPI {
    func start(_ kind: Kind = .focus, minutes: Int64 = 25, label: String? = nil) async throws -> TimerState {
        try await send(.start(kind: kind, plannedMs: minutes * 60_000, label: label, project: nil), source: nil).timer
    }
}

/// `eventually` for conditions that read main-actor state.
@MainActor
func eventuallyOnMain(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
