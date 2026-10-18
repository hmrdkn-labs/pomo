import Foundation
import PomoCoreFFI
import PomoUI

/// Emits `pomo.block_end` when the running block reaches its end time (the Core writes no event for
/// that). Re-arm after every event: any of them can move the end.
final class BlockEndWatcher: @unchecked Sendable {
    private let core: PomoCore
    private let emit: @Sendable (SSEMessage) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(core: PomoCore, emit: @escaping @Sendable (SSEMessage) -> Void) {
        self.core = core; self.emit = emit
    }

    func rearm() {
        guard let t = try? core.timer(), t.status == .running, let block = t.block, let remaining = t.remainingMs else {
            cancel()
            return
        }
        let endedMs = PomoUI.nowMs() + remaining
        let id = block.id
        let emit = self.emit
        let next = Task {
            try? await Task.sleep(for: .milliseconds(remaining + 20))
            if Task.isCancelled { return }
            let body = "{\"block_id\":\"\(id)\",\"outcome\":\"completed\",\"ended_ms\":\(endedMs)}"
            emit(SSEMessage(event: "pomo.block_end", data: body))
        }
        lock.withLock {
            task?.cancel()
            task = next
        }
    }

    func cancel() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }
}
