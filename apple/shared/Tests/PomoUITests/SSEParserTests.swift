import Testing
@testable import PomoUI

@Suite struct SSEParserTests {
    private func parse(_ lines: [String]) -> [SSEMessage] {
        var p = SSEParser()
        return lines.compactMap { p.feed(line: $0) }
    }

    @Test func eventWithData() {
        let m = parse(["event: pomo.event", "data: {\"a\":1}", ""])
        #expect(m == [SSEMessage(event: "pomo.event", data: "{\"a\":1}")])
    }

    @Test func commentsAndKeepalivesAreIgnored() {
        #expect(parse([": keepalive", ""]).isEmpty)
        let m = parse([": keepalive", "", "event: pomo.block_end", "data: x", ""])
        #expect(m.map(\.event) == ["pomo.block_end"])
    }

    @Test func multiLineDataJoinsWithNewline() {
        #expect(parse(["data: a", "data: b", ""]) == [SSEMessage(event: "message", data: "a\nb")])
    }

    @Test func noSpaceAfterColonAndStateResetsBetweenMessages() {
        let m = parse(["event:one", "data:1", "", "data:2", ""])
        #expect(m == [SSEMessage(event: "one", data: "1"), SSEMessage(event: "message", data: "2")])
    }

    @Test func blankLineWithoutDataDispatchesNothing() {
        #expect(parse(["event: x", ""]).isEmpty)
    }
}
