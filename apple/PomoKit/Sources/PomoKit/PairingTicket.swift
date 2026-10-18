import Foundation

/// Reads a scanned QR payload or pasted text as a pairing ticket (`spec/sync.md`: `pomo-pair:` followed by
/// base64url JSON with `ticket` and `secret`).
public enum PairingTicket {
    public static let prefix = "pomo-pair:"

    /// The ticket text, trimmed, when `scanned` has the shape of a pairing ticket; nil for any other QR code.
    public static func parse(_ scanned: String) -> String? {
        let text = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix) else { return nil }
        var b64 = String(text.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ticket"] is String, json["secret"] is String
        else { return nil }
        return text
    }
}
