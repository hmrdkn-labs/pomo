import Foundation

public enum Kind: String, Codable, Sendable, CaseIterable {
    case focus
    case shortBreak = "short_break"
    case longBreak = "long_break"

    public var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        }
    }

    public var isBreak: Bool { self != .focus }
}

public enum TimerStatus: String, Codable, Sendable {
    case idle, running, paused
}

public struct Block: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: Kind
    public var label: String?
    public var project: String?
    public var source: String
    public var deviceId: String
    public var startedMs: Int64
    public var plannedMs: Int64
    public var elapsedMs: Int64
    public var phase: String
    public var outcome: String?
    public var endedMs: Int64?

    public init(
        id: String, kind: Kind, label: String? = nil, project: String? = nil, source: String = "user",
        deviceId: String = "", startedMs: Int64 = 0, plannedMs: Int64, elapsedMs: Int64 = 0,
        phase: String = "running", outcome: String? = nil, endedMs: Int64? = nil
    ) {
        self.id = id; self.kind = kind; self.label = label; self.project = project; self.source = source
        self.deviceId = deviceId; self.startedMs = startedMs; self.plannedMs = plannedMs
        self.elapsedMs = elapsedMs; self.phase = phase; self.outcome = outcome; self.endedMs = endedMs
    }
}

public struct TimerState: Codable, Equatable, Sendable {
    public var status: TimerStatus
    public var block: Block?
    public var remainingMs: Int64?
    public var nextKind: Kind

    public init(status: TimerStatus, block: Block? = nil, remainingMs: Int64? = nil, nextKind: Kind = .focus) {
        self.status = status; self.block = block; self.remainingMs = remainingMs; self.nextKind = nextKind
    }
}

public struct Today: Codable, Equatable, Sendable {
    public var focusMs: Int64
    public var completedFocus: Int

    public init(focusMs: Int64, completedFocus: Int) {
        self.focusMs = focusMs; self.completedFocus = completedFocus
    }
}

public struct Status: Codable, Equatable, Sendable {
    public var nowMs: Int64
    public var timer: TimerState
    public var today: Today

    public init(nowMs: Int64, timer: TimerState, today: Today) {
        self.nowMs = nowMs; self.timer = timer; self.today = today
    }
}

public struct CommandResult: Codable, Equatable, Sendable {
    public var timer: TimerState
    public var replayed: Bool

    public init(timer: TimerState, replayed: Bool) {
        self.timer = timer; self.replayed = replayed
    }
}

public struct StatGroup: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var focusMs: Int64
    public var completedFocus: Int
    public var id: String { key }

    public init(key: String, focusMs: Int64, completedFocus: Int) {
        self.key = key; self.focusMs = focusMs; self.completedFocus = completedFocus
    }
}

public struct Stats: Codable, Equatable, Sendable {
    public var fromMs: Int64
    public var toMs: Int64
    public var tzOffsetMin: Int
    public var focusMs: Int64
    public var completedFocus: Int
    public var streakDays: Int
    public var groups: [StatGroup]

    public init(
        fromMs: Int64 = 0, toMs: Int64 = 0, tzOffsetMin: Int = 0, focusMs: Int64 = 0,
        completedFocus: Int = 0, streakDays: Int = 0, groups: [StatGroup] = []
    ) {
        self.fromMs = fromMs; self.toMs = toMs; self.tzOffsetMin = tzOffsetMin; self.focusMs = focusMs
        self.completedFocus = completedFocus; self.streakDays = streakDays; self.groups = groups
    }
}

struct BlocksResponse: Codable { var blocks: [Block] }

public struct BlockEnd: Codable, Equatable, Sendable {
    public var blockId: String
    public var outcome: String
    public var endedMs: Int64
}

/// A request to change the Timer. Encodes to the body of `POST /v1/commands`.
public enum Command: Equatable, Sendable {
    case start(kind: Kind, plannedMs: Int64, label: String?, project: String?)
    case pause, resume
    case extend(addMs: Int64)
    case skip, stop, reset
    case label(blockId: String?, label: String?)

    public var body: [String: Any] {
        switch self {
        case let .start(kind, plannedMs, label, project):
            var b: [String: Any] = ["type": "start", "kind": kind.rawValue, "planned_ms": plannedMs]
            if let label, !label.isEmpty { b["label"] = label }
            if let project, !project.isEmpty { b["project"] = project }
            return b
        case .pause: return ["type": "pause"]
        case .resume: return ["type": "resume"]
        case let .extend(addMs): return ["type": "extend", "add_ms": addMs]
        case .skip: return ["type": "skip"]
        case .stop: return ["type": "stop"]
        case .reset: return ["type": "reset"]
        case let .label(blockId, label):
            var b: [String: Any] = ["type": "label"]
            if let blockId { b["block_id"] = blockId }
            if let label { b["label"] = label }
            return b
        }
    }
}

public struct APIError: Error, Equatable, Sendable, LocalizedError {
    public var status: Int
    public var code: String
    public var message: String
    public var errorDescription: String? { message }

    public init(status: Int, code: String, message: String) {
        self.status = status; self.code = code; self.message = message
    }
}

public enum ConnectionError: Error, Equatable, Sendable, LocalizedError {
    case daemonNotConfigured(String)
    case unreachable(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .daemonNotConfigured(m), let .unreachable(m), let .badResponse(m): m
        }
    }
}

// MARK: Devices and sync

public struct DeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public var deviceId: String
    public var name: String
    public var paired: Bool
    public var revoked: Bool
    public var id: String { deviceId }

    public init(deviceId: String, name: String, paired: Bool = true, revoked: Bool = false) {
        self.deviceId = deviceId; self.name = name; self.paired = paired; self.revoked = revoked
    }
}

public struct DevicesList: Codable, Equatable, Sendable {
    public var deviceId: String
    public var name: String
    public var devices: [DeviceInfo]

    public init(deviceId: String, name: String, devices: [DeviceInfo] = []) {
        self.deviceId = deviceId; self.name = name; self.devices = devices
    }
}

public struct PairOffer: Codable, Equatable, Sendable {
    public var ticket: String
    /// Absolute expiry, ms since the epoch.
    public var expiresMs: Int64

    public init(ticket: String, expiresMs: Int64) { self.ticket = ticket; self.expiresMs = expiresMs }
}

/// One entry of a `POST /v1/sync` response: counts on success, `error` on a per-peer failure.
public struct PeerSync: Codable, Equatable, Sendable, Identifiable {
    public var deviceId: String
    public var sent: Int?
    public var received: Int?
    public var error: String?
    public var id: String { deviceId }

    public init(deviceId: String, sent: Int? = nil, received: Int? = nil, error: String? = nil) {
        self.deviceId = deviceId; self.sent = sent; self.received = received; self.error = error
    }
}

struct PairJoinResponse: Codable { var device: DeviceInfo }
struct RevokeResponse: Codable { var device: DeviceInfo }
struct SyncResponse: Codable { var synced: [PeerSync] }
