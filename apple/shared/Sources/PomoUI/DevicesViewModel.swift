import Foundation
import Observation

/// How the Devices section can fail, mapped from daemon and transport errors.
public enum DevicesProblem: Equatable, Sendable {
    /// The Daemon cannot be reached.
    case offline(String)
    /// The Daemon runs with `--sync off` (`501 sync_disabled`).
    case syncDisabled
    /// A failed action; the text is meant for the user.
    case failed(String)

    public static func map(_ error: Error) -> DevicesProblem {
        switch error {
        case let e as ConnectionError:
            return .offline(e.localizedDescription)
        case let e as APIError:
            switch (e.status, e.code) {
            case (501, _), (_, "sync_disabled"):
                return .syncDisabled
            case (_, "bad_ticket"):
                return .failed("That ticket is not valid. Copy it again from the other device.")
            case (_, "pairing_rejected"):
                return .failed("The other device refused to pair: \(e.message)")
            case (_, "unauthorized"):
                return .failed("The daemon rejected the access token.")
            default:
                return .failed(e.message)
            }
        default:
            return .failed(error.localizedDescription)
        }
    }

    public var message: String {
        switch self {
        case let .offline(m): "The daemon is not running: \(m)"
        case .syncDisabled: "Sync is turned off. The daemon was started with --sync off."
        case let .failed(m): m
        }
    }
}

public enum DevicesAvailability: Equatable, Sendable {
    case loading
    case ready
    case offline(String)
    case syncDisabled
}

/// A live pairing offer and the time left on it.
public struct OfferState: Equatable, Sendable {
    public var offer: PairOffer
    public var remainingSeconds: Int

    public var isExpired: Bool { remainingSeconds <= 0 }

    /// `m:ss`
    public var countdownText: String {
        let s = max(0, remainingSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor @Observable
public final class DevicesViewModel {
    public private(set) var availability: DevicesAvailability = .loading
    public private(set) var ownName = ""
    public private(set) var ownId = ""
    public private(set) var devices: [DeviceInfo] = []

    public private(set) var offer: OfferState?
    public private(set) var isOffering = false
    public private(set) var offerError: String?
    /// Set when a device appeared while an offer was showing.
    public private(set) var pairedNotice: String?

    public var joinTicket = ""
    public private(set) var isJoining = false
    public private(set) var joinMessage: String?
    public private(set) var joinFailed = false

    public private(set) var isSyncing = false
    public private(set) var syncResults: [PeerSync]?
    public private(set) var syncError: String?

    public private(set) var actionError: String?

    private let connector: @Sendable () async throws -> any DevicesAPI
    private let clock: @Sendable () -> Int64
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var offerSession = false
    @ObservationIgnored private var knownIds: Set<String> = []
    @ObservationIgnored private var pollCountdown = 0

    /// Seconds between device list polls while an offer is showing.
    static let pollEvery = 3

    public init(
        connector: @escaping @Sendable () async throws -> any DevicesAPI,
        clock: @escaping @Sendable () -> Int64 = { PomoUI.nowMs() }
    ) {
        self.connector = connector; self.clock = clock
    }

    // MARK: Loading

    public func load() async {
        do {
            let api = try await connector()
            let list = try await api.devices()
            ownName = list.name; ownId = list.deviceId; devices = list.devices
            availability = .ready
            actionError = nil
        } catch is CancellationError {
        } catch {
            apply(problem: .map(error), reset: true)
        }
    }

    private func apply(problem: DevicesProblem, reset: Bool = false) {
        switch problem {
        case let .offline(m):
            availability = .offline(m)
        case .syncDisabled:
            availability = .syncDisabled
        case let .failed(m):
            actionError = m
            return
        }
        if reset { offer = nil }
    }

    public var activeDevices: [DeviceInfo] { devices.filter { !$0.revoked } }
    public var canSync: Bool { availability == .ready && !activeDevices.isEmpty && !isSyncing }

    // MARK: Pairing offer

    /// Call when the pairing panel becomes visible; fetches an offer and keeps it fresh until `endOfferSession`.
    public func beginOfferSession() async {
        offerSession = true
        pairedNotice = nil
        startLoop()
        await newOffer()
    }

    public func endOfferSession() {
        offerSession = false
        offer = nil
        loop?.cancel()
        loop = nil
    }

    public func newOffer() async {
        guard !isOffering else { return }
        isOffering = true
        defer { isOffering = false }
        do {
            let api = try await connector()
            let o = try await api.pairOffer()
            knownIds = Set(devices.map(\.deviceId))
            offer = OfferState(offer: o, remainingSeconds: Self.remaining(o, now: clock()))
            offerError = nil
            pairedNotice = nil
            availability = .ready
        } catch is CancellationError {
        } catch {
            offer = nil
            switch DevicesProblem.map(error) {
            case let .failed(m): offerError = m
            case let p:
                offerError = nil
                apply(problem: p)
            }
        }
    }

    static func remaining(_ offer: PairOffer, now: Int64) -> Int {
        Int(max(0, (offer.expiresMs - now + 999) / 1000))
    }

    /// One second of the offer clock. Updates the countdown, refreshes an expired offer and notices a new peer.
    public func tick() async {
        guard offerSession else { return }
        if var o = offer {
            o.remainingSeconds = Self.remaining(o.offer, now: clock())
            offer = o
            if o.isExpired { await newOffer(); return }
            pollCountdown += 1
            if pollCountdown >= Self.pollEvery {
                pollCountdown = 0
                await detectPairing()
            }
        }
    }

    /// An offer is single use: when a new Device appears, the offer is spent, so drop it.
    func detectPairing() async {
        do {
            let api = try await connector()
            let list = try await api.devices()
            ownName = list.name; ownId = list.deviceId; devices = list.devices
            let fresh = list.devices.filter { !knownIds.contains($0.deviceId) && !$0.revoked }
            if let d = fresh.first {
                offer = nil
                pairedNotice = "Paired with \(d.name)."
                knownIds = Set(list.devices.map(\.deviceId))
            }
        } catch is CancellationError {
        } catch {
            // Transient; the next tick tries again.
        }
    }

    private func startLoop() {
        loop?.cancel()
        pollCountdown = 0
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await self?.tick()
            }
        }
    }

    // MARK: Join

    public var canJoin: Bool { !joinTicket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isJoining }

    public func join(name: String? = nil) async {
        let ticket = joinTicket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ticket.isEmpty, !isJoining else { return }
        isJoining = true
        joinMessage = nil
        defer { isJoining = false }
        do {
            let api = try await connector()
            let d = try await api.pairJoin(ticket: ticket, name: name)
            joinMessage = "Paired with \(d.name)."
            joinFailed = false
            joinTicket = ""
            await load()
        } catch is CancellationError {
        } catch {
            let p = DevicesProblem.map(error)
            joinMessage = p.message
            joinFailed = true
            if p != .failed(p.message) { apply(problem: p) }
        }
    }

    // MARK: Sync and revoke

    public func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            let api = try await connector()
            syncResults = try await api.sync(deviceId: nil)
        } catch is CancellationError {
        } catch {
            let p = DevicesProblem.map(error)
            syncResults = nil
            syncError = p.message
            if case .failed = p {} else { apply(problem: p) }
        }
    }

    /// The name to show for a device id in sync results.
    public func name(for deviceId: String) -> String {
        devices.first { $0.deviceId == deviceId }?.name ?? String(deviceId.prefix(8))
    }

    public func revoke(_ device: DeviceInfo) async {
        do {
            let api = try await connector()
            let updated = try await api.revoke(deviceId: device.deviceId)
            if let i = devices.firstIndex(where: { $0.deviceId == updated.deviceId }) { devices[i] = updated }
            syncResults = nil
            actionError = nil
        } catch is CancellationError {
        } catch {
            let p = DevicesProblem.map(error)
            actionError = p.message
            if case .failed = p {} else { apply(problem: p) }
        }
    }
}
