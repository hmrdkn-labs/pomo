import Foundation
import Testing
@testable import PomoKit

struct PairingTicketTests {
    private func ticket(_ json: String) -> String {
        let b64 = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "pomo-pair:" + b64
    }

    @Test func acceptsATicketAndTrimsWhitespace() {
        let t = ticket(#"{"ticket":"endpoint...","secret":"abc","name":"mac"}"#)
        #expect(PairingTicket.parse("  \(t)\n") == t)
    }

    @Test func rejectsOtherQRCodes() {
        #expect(PairingTicket.parse("https://example.com") == nil)
        #expect(PairingTicket.parse("") == nil)
        #expect(PairingTicket.parse("pomo-pair:") == nil)
        #expect(PairingTicket.parse("pomo-pair:!!!not base64!!!") == nil)
        #expect(PairingTicket.parse(ticket(#"{"ticket":"x"}"#)) == nil, "no secret")
        #expect(PairingTicket.parse(ticket(#"["ticket","secret"]"#)) == nil)
    }
}
