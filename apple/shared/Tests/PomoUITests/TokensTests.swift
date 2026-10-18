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
        #expect(json["rule"] as? [String: Double] == Tokens.ruleHeights)

        let t = Tokens.TypeSize.self
        let sizes = [
            "countdown-popover": t.countdownPopover, "countdown-phone": t.countdownPhone,
            "countdown-activity": t.countdownActivity, "phase": t.phase, "body": t.body,
            "secondary": t.secondary, "numeral": t.numeral,
        ]
        #expect(sizes.mapValues { Double($0) } == Tokens.typeSizes)

        let s = Tokens.Spacing.self
        #expect([s.xs, s.s, s.m, s.l, s.xl, s.xxl] == Tokens.spacing.map { CGFloat($0) })
        #expect(s.phoneMargin == 24 && s.popoverPadding == 20)

        #expect(Tokens.Radius.control == CGFloat(Tokens.radii["control"]!))
        #expect(Tokens.Radius.surface == CGFloat(Tokens.radii["surface"]!))
        #expect(Tokens.Rule.heightPopover == CGFloat(Tokens.ruleHeights["height-popover"]!))
        #expect(Tokens.Rule.heightPhone == CGFloat(Tokens.ruleHeights["height-phone"]!))
    }

    @Test func hexParsing() throws {
        let c = try #require(Tokens.rgba(hex: "#F5F0E6"))
        #expect(c.a == 1 && abs(c.r - 245.0 / 255) < 1e-9)
        let h = try #require(Tokens.rgba(hex: "#1B161320"))
        #expect(abs(h.a - 32.0 / 255) < 1e-9 && abs(h.r - 27.0 / 255) < 1e-9)
        #expect(Tokens.rgba(hex: "nope") == nil)
    }

    /// WCAG 2.x contrast ratios, computed from the tokens (`spec/tokens.json`), in both appearances.
    @Test func contrastMatchesWCAGReferenceValues() throws {
        #expect(abs(try #require(Tokens.contrast("#000000", "#FFFFFF")) - 21) < 1e-9)
        #expect(abs(try #require(Tokens.contrast("#777777", "#FFFFFF")) - 4.48) < 0.01)
        #expect(Tokens.contrast("#FFFFFF", "nope") == nil)
    }

    private func hex(_ name: String, _ dark: Bool) -> String {
        let pair = Tokens.colors[name]!
        return dark ? pair.dark : pair.light
    }

    /// Every pair `docs/ui-reference.md` requires to reach 4.5:1.
    @Test(arguments: [false, true]) func documentedPairsMeetAA(dark: Bool) throws {
        var pairs: [(String, String, String)] = []
        for text in ["ink", "ink-muted", "danger"] {
            for ground in ["paper", "paper-raised"] {
                pairs.append((text, ground, "\(text) on \(ground)"))
            }
        }
        for (fg, bg, name) in pairs {
            let ratio = try #require(Tokens.contrast(hex(fg, dark), hex(bg, dark)))
            #expect(ratio >= 4.5, "\(name) (\(dark ? "dark" : "light")): \(ratio)")
        }
        // Text on the focus fill: white in light, the dark paper in dark.
        let onFocus = dark ? hex("paper", true) : "#FFFFFF"
        let ratio = try #require(Tokens.contrast(onFocus, hex("focus", dark)))
        #expect(ratio >= 4.5, "text on focus (\(dark ? "dark" : "light")): \(ratio)")
        // Text on the ink fill (the Pause / Resume button): the paper colour.
        let onInk = try #require(Tokens.contrast(hex("paper", dark), hex("ink", dark)))
        #expect(onInk >= 4.5, "paper on ink (\(dark ? "dark" : "light")): \(onInk)")
    }

    /// The Live Activity is `ink` in both appearances, with its own text colours.
    @Test func liveActivityPairsMeetAA() throws {
        for (fg, name) in [
            (ActivityPalette.textHex, "text"), (ActivityPalette.mutedHex, "label"),
            (ActivityPalette.focusHex, "focus rule"), (ActivityPalette.breakHex, "break rule"),
        ] {
            let ratio = try #require(Tokens.contrast(fg, ActivityPalette.groundHex))
            #expect(ratio >= 4.5, "\(name) on the Live Activity ground: \(ratio)")
        }
    }

    @Test func themeResolvesBothAppearancesAndIncreasedContrast() {
        let light = Theme(.light), dark = Theme(.dark)
        #expect(light.paper != dark.paper)
        #expect(Theme(.light, contrast: .increased).hairline == light.inkMuted)
        #expect(Theme(.dark, contrast: .increased).hairline == dark.inkMuted)
        #expect(light.hairline != light.inkMuted)
    }
}
