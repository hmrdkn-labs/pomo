import SwiftUI

/// Phase glyph and name in small caps, with an optional trailing byline ("by claude"). Phase is never colour
/// alone: the glyph and the name both show.
public struct PhaseLine: View {
    public var glyph: Glyph
    public var title: String
    public var detail: String?
    public var byline: String?
    public var tint: Color
    public var titleIdentifier: String?
    public var bylineIdentifier: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pomoTheme) private var theme

    public init(
        glyph: Glyph, title: String, detail: String? = nil, byline: String? = nil, tint: Color,
        titleIdentifier: String? = nil, bylineIdentifier: String? = nil
    ) {
        self.glyph = glyph; self.title = title; self.detail = detail; self.byline = byline; self.tint = tint
        self.titleIdentifier = titleIdentifier; self.bylineIdentifier = bylineIdentifier
    }

    public var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: glyph.symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .pomoFont(.phase)
                .foregroundStyle(theme.ink)
                .accessibilityIdentifier(titleIdentifier ?? "")
            if let detail {
                Text(detail).pomoFont(.phase, weight: .regular).foregroundStyle(theme.inkMuted)
            }
            Spacer(minLength: Tokens.Spacing.s)
            if let byline {
                Text(byline)
                    .pomoFont(.secondary)
                    .foregroundStyle(theme.inkMuted)
                    .accessibilityIdentifier(bylineIdentifier ?? "")
            }
        }
        // 200 ms cross-fade of glyph and colour on a phase change; an instant swap with Reduce Motion.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: glyph)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: title)
    }
}
