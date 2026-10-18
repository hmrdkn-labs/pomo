import SwiftUI

/// Design tokens of "Paper and ink". Mirrors `spec/tokens.json`; `TokensTests` fails if they drift.
public enum Tokens {
    public struct ColorPair: Equatable, Sendable {
        public let light: String
        public let dark: String
    }

    /// Keyed by the names in `spec/tokens.json`.
    public static let colors: [String: ColorPair] = [
        "paper": .init(light: "#F5F0E6", dark: "#14110F"),
        "paper-raised": .init(light: "#FFFDF8", dark: "#1E1A17"),
        "ink": .init(light: "#1B1613", dark: "#F3EDE2"),
        "ink-muted": .init(light: "#6F655B", dark: "#A39789"),
        "focus": .init(light: "#D63A22", dark: "#FF6A4D"),
        "break": .init(light: "#4D5B6B", dark: "#8FA3B8"),
        "danger": .init(light: "#A12A1B", dark: "#E5806C"),
        "hairline": .init(light: "#1B161320", dark: "#F3EDE226"),
    ]

    public enum TypeSize {
        public static let countdownPopover: CGFloat = 84
        public static let countdownPhone: CGFloat = 104
        public static let countdownActivity: CGFloat = 40
        public static let phase: CGFloat = 12
        public static let body: CGFloat = 17
        public static let secondary: CGFloat = 13
        public static let numeral: CGFloat = 15
    }

    /// Keyed by the names in `spec/tokens.json`.
    public static let typeSizes: [String: Double] = [
        "countdown-popover": 84, "countdown-phone": 104, "countdown-activity": 40,
        "phase": 12, "body": 17, "secondary": 13, "numeral": 15,
    ]

    /// The iPhone countdown scales with Dynamic Type between these sizes.
    public static let countdownPhoneRange: ClosedRange<CGFloat> = 80...120

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 40
        /// Screen margin on iPhone.
        public static let phoneMargin: CGFloat = 24
        /// Padding inside the Mac popover.
        public static let popoverPadding: CGFloat = 20
    }

    public static let spacing: [Double] = [4, 8, 12, 16, 24, 40]

    public enum Radius {
        public static let control: CGFloat = 10
        public static let surface: CGFloat = 14
    }

    public static let radii: [String: Double] = ["control": 10, "surface": 14]

    public enum Rule {
        public static let heightPopover: CGFloat = 3
        public static let heightPhone: CGFloat = 4
    }

    public static let ruleHeights: [String: Double] = ["height-popover": 3, "height-phone": 4]

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
        return Color(cgColor: CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [c.r, c.g, c.b, c.a])!)
    }

    /// WCAG 2.x relative luminance of an opaque sRGB colour.
    public static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio, 1...21, of two opaque `#RRGGBB` colours; nil if either does not parse.
    public static func contrast(_ a: String, _ b: String) -> Double? {
        guard let x = rgba(hex: a), let y = rgba(hex: b) else { return nil }
        let la = luminance((x.r, x.g, x.b)), lb = luminance((y.r, y.g, y.b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// Resolved palette for one colour scheme. Increase Contrast turns hairlines into `ink-muted`.
public struct Theme: Sendable {
    public let scheme: ColorScheme
    public let highContrast: Bool

    public init(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) {
        self.scheme = scheme
        self.highContrast = contrast == .increased
    }

    public var paper: Color { Tokens.color("paper", scheme) }
    public var paperRaised: Color { Tokens.color("paper-raised", scheme) }
    public var ink: Color { Tokens.color("ink", scheme) }
    public var inkMuted: Color { Tokens.color("ink-muted", scheme) }
    public var focus: Color { Tokens.color("focus", scheme) }
    public var breakAccent: Color { Tokens.color("break", scheme) }
    public var danger: Color { Tokens.color("danger", scheme) }
    public var hairline: Color { highContrast ? inkMuted : Tokens.color("hairline", scheme) }

    /// Text on a `focus` fill: white on the light red, `paper` dark on the light-on-dark red.
    public var onFocus: Color { scheme == .dark ? Tokens.color("paper", .dark) : .white }

    /// Text on an `ink` fill.
    public var onInk: Color { paper }

    public func accent(for kind: Kind) -> Color { kind == .focus ? focus : breakAccent }

    /// Rule and glyph colour for a Timer: `focus` while a focus block runs, `break` for a running break,
    /// `ink-muted` while paused, `ink` when idle.
    public func phaseTint(_ countdown: Countdown) -> Color {
        switch countdown.status {
        case .idle: ink
        case .paused: inkMuted
        case .running: accent(for: countdown.kind ?? .focus)
        }
    }
}

/// The Live Activity and Dynamic Island are `ink` in both appearances, so their text and rule colours come
/// from fixed tokens rather than the current appearance: the light `ink` as ground, light `paper` for text, and
/// the dark variants of `ink-muted`, `focus` and `break` (the light ones fall below 4.5:1 on that ground).
public enum ActivityPalette {
    public static let ground = Tokens.color("ink", .light)
    public static let text = Tokens.color("paper", .light)
    public static let muted = Tokens.color("ink-muted", .dark)
    public static let focus = Tokens.color("focus", .dark)
    public static let breakAccent = Tokens.color("break", .dark)

    public static let groundHex = Tokens.colors["ink"]!.light
    public static let textHex = Tokens.colors["paper"]!.light
    public static let mutedHex = Tokens.colors["ink-muted"]!.dark
    public static let focusHex = Tokens.colors["focus"]!.dark
    public static let breakHex = Tokens.colors["break"]!.dark

    public static func accent(for kind: Kind) -> Color { kind == .focus ? focus : breakAccent }
}

public extension EnvironmentValues {
    /// The palette for the current colour scheme and contrast setting.
    var pomoTheme: Theme { Theme(colorScheme, contrast: colorSchemeContrast) }
}
