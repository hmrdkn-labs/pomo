import SwiftUI

/// Design tokens. Mirrors `spec/tokens.json`; `TokensTests` fails if they drift.
public enum Tokens {
    public struct ColorPair: Equatable, Sendable {
        public let light: String
        public let dark: String
    }

    public static let colors: [String: ColorPair] = [
        "bg": .init(light: "#F6F3EC", dark: "#0F1A14"),
        "surface": .init(light: "#FFFFFF", dark: "#16251C"),
        "text": .init(light: "#16251C", dark: "#EDE9DD"),
        "text-muted": .init(light: "#5E6B62", dark: "#98A59C"),
        "focus": .init(light: "#2F6B47", dark: "#5FB583"),
        "break": .init(light: "#B7791F", dark: "#E0A94A"),
        "danger": .init(light: "#B3412E", dark: "#E27763"),
        "hairline": .init(light: "#00000014", dark: "#FFFFFF1A"),
    ]

    public enum TypeSize {
        public static let countdown: CGFloat = 56
        public static let body: CGFloat = 17
        public static let secondary: CGFloat = 13
        public static let caption: CGFloat = 11
    }

    public static let typeSizes: [String: Double] = [
        "countdown": 56, "body": 17, "secondary": 13, "caption": 11,
    ]

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    public static let spacing: [Double] = [4, 8, 12, 16, 24]

    public enum Radius {
        public static let card: CGFloat = 12
        public static let control: CGFloat = 8
    }

    public static let radii: [String: Double] = ["card": 12, "control": 8]

    public enum Ring {
        public static let stroke: CGFloat = 6
    }

    public static let ringStroke: Double = 6

    /// Parses `#RRGGBB` or `#RRGGBBAA` into 0...1 components.
    public static func rgba(hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
        }
        return (
            Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
            Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255
        )
    }

    public static func color(_ name: String, _ scheme: ColorScheme) -> Color {
        guard let pair = colors[name], let c = rgba(hex: scheme == .dark ? pair.dark : pair.light) else {
            return .clear
        }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

/// Resolved palette for one color scheme.
public struct Theme: Sendable {
    public let scheme: ColorScheme
    public init(_ scheme: ColorScheme) { self.scheme = scheme }

    public var bg: Color { Tokens.color("bg", scheme) }
    public var surface: Color { Tokens.color("surface", scheme) }
    public var text: Color { Tokens.color("text", scheme) }
    public var textMuted: Color { Tokens.color("text-muted", scheme) }
    public var focus: Color { Tokens.color("focus", scheme) }
    public var breakAccent: Color { Tokens.color("break", scheme) }
    public var danger: Color { Tokens.color("danger", scheme) }
    public var hairline: Color { Tokens.color("hairline", scheme) }

    public func accent(for kind: Kind) -> Color { kind == .focus ? focus : breakAccent }
}
