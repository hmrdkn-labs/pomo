import SwiftUI

/// The progress rule: full width, square ends, hairline track, starts full and shortens from the right.
/// Its length derives from the Countdown's absolute end time on every frame, so it never drifts from the clock.
/// With Reduce Motion it redraws once per second instead.
public struct ProgressRule: View {
    public var countdown: Countdown
    public var tint: Color
    public var height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pomoTheme) private var theme

    public init(countdown: Countdown, tint: Color, height: CGFloat) {
        self.countdown = countdown; self.tint = tint; self.height = height
    }

    public var body: some View {
        if countdown.status == .running {
            if reduceMotion {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in bar(at: ctx.date) }
            } else {
                TimelineView(.animation) { ctx in bar(at: ctx.date) }
            }
        } else {
            bar(at: .now)
        }
    }

    private func bar(at date: Date) -> some View {
        RuleBar(fraction: countdown.remainingFraction(at: Int64((date.timeIntervalSince1970 * 1000).rounded())), tint: tint, track: theme.hairline, height: height)
    }
}

/// A rule at a fixed fraction (0...1 of the width), without any clock.
public struct RuleBar: View {
    public var fraction: Double
    public var tint: Color
    public var track: Color
    public var height: CGFloat

    public init(fraction: Double, tint: Color, track: Color, height: CGFloat) {
        self.fraction = fraction; self.tint = tint; self.track = track; self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle().fill(tint).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The primary action: full width, radius 10, filled. `focus` for starting a focus block, `ink` otherwise.
public struct PomoPrimaryButtonStyle: ButtonStyle {
    public enum Tone: Sendable { case focus, ink }

    public var tone: Tone
    public var height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.pomoTheme) private var theme

    public init(tone: Tone, height: CGFloat = 44) { self.tone = tone; self.height = height }

    public func makeBody(configuration: Configuration) -> some View {
        let fill = tone == .focus ? theme.focus : theme.ink
        let text = tone == .focus ? theme.onFocus : theme.onInk
        configuration.label
            .pomoFont(.body, weight: .semibold)
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
    }
}

/// Text-and-symbol button with no fill. `muted` uses `ink-muted` (Reset, Stop).
public struct PomoSecondaryButtonStyle: ButtonStyle {
    public var muted: Bool
    public var minHeight: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.pomoTheme) private var theme

    public init(muted: Bool = false, minHeight: CGFloat = 32) { self.muted = muted; self.minHeight = minHeight }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pomoFont(.secondary, weight: .medium)
            .foregroundStyle(muted ? theme.inkMuted : theme.ink)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
