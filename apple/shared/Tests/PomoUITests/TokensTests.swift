import Foundation
import Testing
@testable import PomoUI

@Suite struct TokensTests {
    static func tokensJSON() throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // file, PomoUITests, Tests, shared, apple -> repo root
        let data = try Data(contentsOf: url.appendingPathComponent("spec/tokens.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func colorsMatchSpec() throws {
        let json = try Self.tokensJSON()
        let colors = try #require(json["color"] as? [String: [String: String]])
        #expect(Set(colors.keys) == Set(Tokens.colors.keys))
        for (name, pair) in colors {
            #expect(Tokens.colors[name]?.light == pair["light"], "\(name) light")
            #expect(Tokens.colors[name]?.dark == pair["dark"], "\(name) dark")
        }
    }

    @Test func typeSpacingShapeMatchSpec() throws {
        let json = try Self.tokensJSON()
        #expect(json["type"] as? [String: Double] == Tokens.typeSizes)
        #expect(json["spacing"] as? [Double] == Tokens.spacing)
        #expect(json["radius"] as? [String: Double] == Tokens.radii)
        #expect((json["ring"] as? [String: Double])?["stroke"] == Tokens.ringStroke)
        #expect(Tokens.TypeSize.countdown == 56 && Tokens.TypeSize.body == 17)
        #expect([Tokens.Spacing.xs, Tokens.Spacing.s, Tokens.Spacing.m, Tokens.Spacing.l, Tokens.Spacing.xl] == Tokens.spacing.map { CGFloat($0) })
        #expect(Tokens.Radius.card == CGFloat(Tokens.radii["card"]!) && Tokens.Radius.control == CGFloat(Tokens.radii["control"]!))
        #expect(Tokens.Ring.stroke == CGFloat(Tokens.ringStroke))
    }

    @Test func hexParsing() throws {
        let c = try #require(Tokens.rgba(hex: "#F6F3EC"))
        #expect(c.a == 1 && abs(c.r - 246.0 / 255) < 1e-9)
        let h = try #require(Tokens.rgba(hex: "#FFFFFF1A"))
        #expect(abs(h.a - 26.0 / 255) < 1e-9 && h.r == 1)
        #expect(Tokens.rgba(hex: "nope") == nil)
    }
}
