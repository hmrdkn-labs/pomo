import Foundation
import Observation

public struct BlockEndNotice: Equatable, Sendable {
    public var kind: Kind
    public var label: String?
}

/// Retry delays for reconnecting to the Daemon.
public enum Backoff {
    public static let steps: [Double] = [0.5, 1, 2, 4, 8, 15, 30]
    public static func delay(attempt: Int) -> Duration {
        .milliseconds(Int(steps[min(max(attempt, 0), steps.count - 1)] * 1000))
    }
}

public enum Glyph: Equatable, Sendable {
    case idle, focus, breakTime, paused, offline

    public var symbol: String {
        switch self {
        case .idle: "circle"
        case .focus: "circle.fill"
        case .breakTime: "cup.and.saucer.fill"
        case .paused: "pause.fill"
        case .offline: "exclamationmark.circle"
        }
    }
}

public enum Connection: Equatable, Sendable {
    case connecting
    case online
    case offline(String)
}

@MainActor @Observable
public final class TimerViewModel {
    public private(set) var connection: Connection = .connecting
    public private(set) var countdown: Countdown = .idle
    public private(set) var block: Block?
    public private(set) var nextKind: Kind = .focus
    public private(set) var today = Today(focusMs: 0, completedFocus: 0)
    public private(set) var lastBlock: Block?
    public private(set) var nowMs: Int64
    public private(set) var lastError: String?
    /// Bumped whenever state was refetched wholesale: the stream (re)opened or the Daemon sent `pomo.resync`.
    /// Views showing data this model does not own (statistics) reload on change.
    public private(set) var resyncCount = 0
    public var labelDraft = ""
    public var kindOverride: Kind?

    public let settings: PomoSettings

    @ObservationIgnored private let connector: @Sendable () async throws -> any PomoAPI
    @ObservationIgnored private let clock: @Sendable () -> Int64
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let runTicker: Bool
    @ObservationIgnored private let resyncInterval: Duration
    @ObservationIgnored private var api: (any PomoAPI)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var draftBlockId: String?
    /// Called when a `pomo.block_end` event arrives.
    @ObservationIgnored public var onBlockEnd: (@MainActor (BlockEndNotice) -> Void)?
    /// Called just before this app issues a `start` command (lazy notification permission).
    @ObservationIgnored public var onWillStart: (@MainActor () -> Void)?

    public init(
        settings: PomoSettings,
        connector: @escaping @Sendable () async throws -> any PomoAPI,
        clock: @escaping @Sendable () -> Int64 = { PomoUI.nowMs() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        runTicker: Bool = true,
        resyncInterval: Duration = .seconds(30)
    ) {
        self.settings = settings
        self.connector = connector
        self.clock = clock
        self.sleep = sleep
        self.runTicker = runTicker
        self.resyncInterval = resyncInterval
        self.nowMs = clock()
    }

    // MARK: Derived display state

    public var isOnline: Bool { connection == .online }
    public var isLive: Bool { countdown.status != .idle }

    public var glyph: Glyph {
        if case .offline = connection { return .offline }
        switch countdown.status {
        case .idle: return .idle
        case .paused: return .paused
        case .running: return countdown.kind?.isBreak == true ? .breakTime : .focus
        }
    }

    /// Text beside the glyph in the menu bar: `mm:ss` while a block is live, empty when idle or offline.
    public var menuTitle: String {
        guard isOnline, isLive else { return "" }
        return countdown.display(at: nowMs)
    }

    public var display: String { countdown.display(at: nowMs) }
    public var progress: Double { countdown.progress(at: nowMs) }

    public var isFinishedLocally: Bool {
        countdown.status == .running && countdown.remainingMs(at: nowMs) == 0
    }

    public var effectiveKind: Kind { kindOverride ?? nextKind }

    public var phaseName: String {
        switch countdown.status {
        case .idle: return "Ready"
        case .paused: return "Paused"
        case .running: return isFinishedLocally ? "Completed" : (countdown.kind?.title ?? "Focus")
        }
    }

    public var phaseDetail: String? {
        guard countdown.status == .paused, let k = countdown.kind else { return nil }
        return k.title
    }

    public var sourceTag: String? { block.flatMap { PomoUI.sourceTag($0.source) } }

    public var lastBlockSummary: String? {
        guard countdown.status == .idle, let b = lastBlock, let outcome = b.outcome else { return nil }
        return "Last: \(b.kind.title.lowercased()) \(outcome)"
    }

    public var accessibilityTime: String {
        let secs = countdown.remainingMs(at: nowMs) / 1000
        let m = secs / 60, s = secs % 60
        return "\(m) minutes \(s) seconds remaining"
    }

    // MARK: Lifecycle

    public func connect() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    public func retry() {
        runTask?.cancel()
        runTask = nil
        connection = .connecting
        connect()
    }

    public func disconnect() {
        runTask?.cancel()
        runTask = nil
    }

    public func tick() {
        if countdown.status == .running { nowMs = clock() }
    }

    func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let api = try await connector()
                self.api = api
                try await refresh(api)
                connection = .online
                attempt = 0
                try await session(api)
                try await sleep(.seconds(1))  // stream closed cleanly; reconnect
            } catch is CancellationError {
                return
            } catch {
                api = nil
                connection = .offline(error.localizedDescription)
                do { try await sleep(Backoff.delay(attempt: attempt)) } catch { return }
                attempt += 1
            }
        }
    }

    private func session(_ api: any PomoAPI) async throws {
        let resync = Task { @MainActor in try? await self.resyncLoop(api) }
        let ticker = Task { @MainActor in
            if self.runTicker { try? await self.tickLoop() }
        }
        defer { resync.cancel(); ticker.cancel() }
        try await listen(api)
    }

    private func listen(_ api: any PomoAPI) async throws {
        for try await event in api.stream() {
            switch event {
            case .opened:
                try await refresh(api)
                resyncCount += 1
            case let .message(m) where m.event == "pomo.resync":
                // This client fell behind and events were dropped: same as a reconnect.
                try await refresh(api)
                resyncCount += 1
            case let .message(m):
                if m.event == "pomo.block_end", let d = m.data.data(using: .utf8),
                   let end = try? Self.decoder.decode(BlockEnd.self, from: d)
                {
                    let known = block?.id == end.blockId ? block : nil
                    onBlockEnd?(BlockEndNotice(kind: known?.kind ?? .focus, label: known?.label))
                }
                try await refresh(api)
            }
        }
    }

    private func resyncLoop(_ api: any PomoAPI) async throws {
        while true {
            try await sleep(resyncInterval)
            try await refresh(api)
        }
    }

    private func tickLoop() async throws {
        while true {
            tick()
            let ms = countdown.msUntilNextTick(at: nowMs).map { $0 + 5 } ?? 1000
            try await sleep(.milliseconds(ms))
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: State

    public func refresh(_ api: any PomoAPI) async throws {
        let s = try await api.status()
        var recent: [Block] = []
        if s.timer.status == .idle { recent = (try? await api.blocks(fromMs: nil, toMs: nil, limit: 100)) ?? [] }
        apply(s, recent: recent)
    }

    func apply(_ s: Status, recent: [Block] = []) {
        countdown = Countdown(timer: s.timer, nowMs: s.nowMs)
        block = s.timer.block
        let idle = s.timer.status == .idle
        nextKind = idle
            ? Cadence.nextKind(recent: recent, every: settings.longBreakEvery, fallback: s.timer.nextKind)
            : s.timer.nextKind
        today = s.today
        lastBlock = idle ? recent.first : nil
        nowMs = clock()
        if block?.id != draftBlockId {
            draftBlockId = block?.id
            if let b = block { labelDraft = b.label ?? "" }
        }
        if !idle { kindOverride = nil }
    }

    // MARK: Commands

    public func start() async {
        let kind = effectiveKind
        onWillStart?()
        await perform(.start(kind: kind, plannedMs: settings.plannedMs(for: kind), label: labelDraft, project: nil))
        kindOverride = nil
    }

    public func pause() async { await perform(.pause) }
    public func resume() async { await perform(.resume) }
    public func extend(minutes: Int = 5) async { await perform(.extend(addMs: Int64(minutes) * 60_000)) }
    public func skip() async { await perform(.skip) }
    public func reset() async { await perform(.reset) }
    public func stop() async { await perform(.stop) }

    public func commitLabel() async {
        guard let id = block?.id else { return }
        await perform(.label(blockId: id, label: labelDraft))
    }

    public func togglePause() async {
        switch countdown.status {
        case .running: await pause()
        case .paused: await resume()
        case .idle: await start()
        }
    }

    func perform(_ command: Command) async {
        guard let api else {
            lastError = "Daemon is not connected"
            return
        }
        do {
            let r = try await api.send(command, source: nil)
            lastError = nil
            if r.timer.status != .idle { apply(Status(nowMs: clock(), timer: r.timer, today: today)) }
            try? await refresh(api)
        } catch let e as APIError {
            lastError = e.message
            try? await refresh(api)
        } catch is CancellationError {
        } catch {
            lastError = error.localizedDescription
            connection = .offline(error.localizedDescription)
            retry()
        }
    }
}
