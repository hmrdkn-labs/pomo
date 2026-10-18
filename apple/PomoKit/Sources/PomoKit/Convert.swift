import Foundation
import PomoCoreFFI
import PomoUI

// Core* (generated, Swift-native records of the FFI) to PomoUI's types, which mirror the Daemon's JSON.

extension PomoUI.Kind {
    init(_ k: CoreKind) {
        switch k {
        case .focus: self = .focus
        case .shortBreak: self = .shortBreak
        case .longBreak: self = .longBreak
        }
    }

    var core: CoreKind {
        switch self {
        case .focus: .focus
        case .shortBreak: .shortBreak
        case .longBreak: .longBreak
        }
    }
}

extension PomoUI.TimerStatus {
    init(_ s: CoreTimerStatus) {
        switch s {
        case .idle: self = .idle
        case .running: self = .running
        case .paused: self = .paused
        }
    }
}

extension PomoUI.Block {
    init(_ b: CoreBlock) {
        self.init(
            id: b.id, kind: Kind(b.kind), label: b.label, project: b.project, source: b.source,
            deviceId: b.deviceId, startedMs: b.startedMs, plannedMs: b.plannedMs, elapsedMs: b.elapsedMs,
            phase: Self.phase(b.phase), outcome: b.outcome.map(Self.outcome), endedMs: b.endedMs
        )
    }

    private static func phase(_ p: CorePhase) -> String {
        switch p {
        case .running: "running"
        case .paused: "paused"
        case .ended: "ended"
        }
    }

    private static func outcome(_ o: CoreOutcome) -> String {
        switch o {
        case .completed: "completed"
        case .skipped: "skipped"
        case .abandoned: "abandoned"
        }
    }
}

extension PomoUI.TimerState {
    init(_ t: CoreTimer) {
        self.init(
            status: TimerStatus(t.status), block: t.block.map(Block.init), remainingMs: t.remainingMs,
            nextKind: Kind(t.nextKind)
        )
    }
}

extension PomoUI.Status {
    init(_ s: CoreStatus) {
        self.init(
            nowMs: s.nowMs, timer: TimerState(s.timer),
            today: Today(focusMs: s.today.focusMs, completedFocus: Int(s.today.completedFocus))
        )
    }
}

extension PomoUI.Stats {
    init(_ s: CoreStats) {
        self.init(
            fromMs: s.fromMs, toMs: s.toMs, tzOffsetMin: Int(s.tzOffsetMin), focusMs: s.focusMs,
            completedFocus: Int(s.completedFocus), streakDays: Int(s.streakDays),
            groups: s.groups.map { StatGroup(key: $0.key, focusMs: $0.focusMs, completedFocus: Int($0.completedFocus)) }
        )
    }
}

extension PomoUI.DeviceInfo {
    init(_ d: CoreDevice) {
        self.init(deviceId: d.deviceId, name: d.name ?? "", paired: d.paired, revoked: d.revoked)
    }
}

extension PomoUI.PeerSync {
    init(_ r: CoreSyncResult) {
        if let error = r.error {
            self.init(deviceId: r.deviceId, error: error)
        } else {
            self.init(deviceId: r.deviceId, sent: Int(r.sent), received: Int(r.received))
        }
    }
}

extension PomoUI.Command {
    /// `nil` label fields and empty strings are dropped, as in `Command.body` (the HTTP body).
    var core: CoreCommand {
        switch self {
        case let .start(kind, plannedMs, label, project):
            .start(
                kind: kind.core, plannedMs: plannedMs, label: label.flatMap { $0.isEmpty ? nil : $0 },
                project: project.flatMap { $0.isEmpty ? nil : $0 }
            )
        case .pause: .pause
        case .resume: .resume
        case let .extend(addMs): .extend(addMs: addMs)
        case .skip: .skip
        case .stop: .stop
        case .reset: .reset
        case let .label(blockId, label): .label(blockId: blockId, label: label, project: nil)
        }
    }
}

extension CoreEvent {
    /// The event envelope as JSON (spec/events.md), the same text the Daemon sends as `pomo.event`.
    var json: String {
        var o: [String: Any] = [
            "id": id, "device_id": deviceId, "seq": seq, "hlc_ms": hlcMs, "hlc_counter": hlcCounter,
            "type": eventType, "source": source,
        ]
        o["payload"] = (try? JSONSerialization.jsonObject(with: Data(payloadJson.utf8))) ?? [String: Any]()
        o["command_key"] = commandKey ?? NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Maps FFI errors to the `APIError` PomoUI's view-models already understand (same codes as the Daemon).
func apiError(_ error: Error) -> Error {
    guard let e = error as? CoreError else { return error }
    switch e {
    case let .InvalidArgument(m): return APIError(status: 400, code: "bad_request", message: m)
    case let .InvalidState(m): return APIError(status: 409, code: "invalid_state", message: m)
    case let .NotFound(m): return APIError(status: 404, code: "not_found", message: m)
    case let .BadTicket(m): return APIError(status: 400, code: "bad_ticket", message: m)
    case let .PairingRejected(m):
        let prefix = "the other Device rejected the pairing: "
        return APIError(
            status: 409, code: "pairing_rejected", message: m.hasPrefix(prefix) ? String(m.dropFirst(prefix.count)) : m
        )
    case let .Sync(m): return APIError(status: 500, code: "sync_failed", message: m)
    case let .Internal(m): return APIError(status: 500, code: "internal", message: m)
    }
}
