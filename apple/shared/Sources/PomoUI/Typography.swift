import SwiftUI

/// Type roles from `spec/tokens.json`. Sizes are the design sizes; on iPhone they follow Dynamic Type.
public enum TypeRole: Sendable {
    case phase, body, secondary, numeral

    var size: CGFloat {
        switch self {
        case .phase: Tokens.TypeSize.phase
        case .body: Tokens.TypeSize.body
        case .secondary: Tokens.TypeSize.secondary
        case .numeral: Tokens.TypeSize.numeral
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .phase: .caption
        case .body: .body
        case .secondary: .footnote
        case .numeral: .subheadline
        }
    }
}

private struct RoleFont: ViewModifier {
    var role: TypeRole
    var weight: Font.Weight?
    @ScaledMetric private var size: CGFloat

    init(role: TypeRole, weight: Font.Weight?) {
        self.role = role
        self.weight = weight
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.textStyle)
    }

    func body(content: Content) -> some View {
        switch role {
        case .phase:
            content.font(.system(size: size, weight: weight ?? .semibold).smallCaps()).tracking(1.2)
        case .body:
            content.font(.system(size: size, weight: weight ?? .regular))
        case .secondary:
            content.font(.system(size: size, weight: weight ?? .regular))
        case .numeral:
            content.font(.system(size: size, weight: weight ?? .regular, design: .serif).italic().monospacedDigit())
        }
    }
}

public extension View {
    /// Applies a type role: `phase` is semibold small caps with +1.2 tracking, `numeral` is serif italic.
    func pomoFont(_ role: TypeRole, weight: Font.Weight? = nil) -> some View {
        modifier(RoleFont(role: role, weight: weight))
    }

    /// No box: a 1 pt hairline underline under a plain field.
    func underlineField() -> some View {
        modifier(UnderlineField())
    }
}

private struct UnderlineField: ViewModifier {
    @Environment(\.pomoTheme) private var theme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.vertical, Tokens.Spacing.s)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 1) }
    }
}

/// A 1 pt divider in the hairline colour.
public struct Hairline: View {
    @Environment(\.pomoTheme) private var theme
    public init() {}
    public var body: some View { Rectangle().fill(theme.hairline).frame(height: 1) }
}

/// The serif countdown: light, monospaced digits, left-aligned. On iPhone the size follows Dynamic Type within
/// 80...120 pt; the Mac popover and the Live Activity use fixed sizes.
public struct CountdownNumerals: View {
    public enum Style: Sendable { case popover, phone, activity }

    var text: String
    var style: Style
    var color: Color?
    var spokenLabel: String?
    var identifier: String?
    @ScaledMetric(relativeTo: .largeTitle) private var phoneSize = Tokens.TypeSize.countdownPhone
    @Environment(\.pomoTheme) private var theme

    /// `spokenLabel` replaces the digits for VoiceOver ("24 minutes 59 seconds remaining"); `identifier` is the
    /// accessibility identifier of the text itself, so UI tests see a static text.
    public init(_ text: String, style: Style, color: Color? = nil, spokenLabel: String? = nil, identifier: String? = nil) {
        self.text = text; self.style = style; self.color = color
        self.spokenLabel = spokenLabel; self.identifier = identifier
    }

    private var size: CGFloat {
        switch style {
        case .popover: Tokens.TypeSize.countdownPopover
        case .phone: min(max(phoneSize, Tokens.countdownPhoneRange.lowerBound), Tokens.countdownPhoneRange.upperBound)
        case .activity: Tokens.TypeSize.countdownActivity
        }
    }

    public var body: some View {
        Text(text)
            .font(.system(size: size, weight: .light, design: .serif).monospacedDigit())
            .foregroundStyle(color ?? theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel(spokenLabel ?? text)
            .accessibilityIdentifier(identifier ?? "")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
