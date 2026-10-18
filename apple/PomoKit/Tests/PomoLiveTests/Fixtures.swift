import Foundation
import PomoUI

let min1: Int64 = 60_000
let t0: Int64 = 1_800_000_000_000

func timer(
    _ status: TimerStatus, kind: Kind = .focus, planned: Int64 = 25 * min1, remaining: Int64? = nil,
    label: String? = nil, id: String = "b1"
) -> TimerState {
    guard status != .idle else { return TimerState(status: .idle, nextKind: .focus) }
    let block = Block(id: id, kind: kind, label: label, plannedMs: planned, phase: status.rawValue)
    return TimerState(status: status, block: block, remainingMs: remaining ?? planned, nextKind: .shortBreak)
}
