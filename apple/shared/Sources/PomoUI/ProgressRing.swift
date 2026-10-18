import SwiftUI

/// A 6 pt ring with round caps. The sweep animates unless Reduce Motion is on.
public struct ProgressRing: View {
    public var progress: Double
    public var tint: Color
    public var track: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(progress: Double, tint: Color, track: Color) {
        self.progress = progress; self.tint = tint; self.track = track
    }

    public var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: Tokens.Ring.stroke)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: Tokens.Ring.stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)
        }
        .padding(Tokens.Ring.stroke / 2)
    }
}
