import Foundation
import PomoKit

/// Decides which scanned QR payloads become a pairing attempt: only Pomo pairing tickets, and the same
/// ticket at most once per `cooldown` (the camera reports a code many times per second).
struct ScanGate {
    var cooldown: TimeInterval = 3
    private var lastTicket: String?
    private var lastAt: Date?

    mutating func accept(_ payload: String, now: Date) -> String? {
        guard let ticket = PairingTicket.parse(payload) else { return nil }
        if ticket == lastTicket, let lastAt, now.timeIntervalSince(lastAt) < cooldown { return nil }
        lastTicket = ticket
        lastAt = now
        return ticket
    }
}
