import ActivityKit
import Foundation
import PomoLive
import PomoUI

/// Starts, updates and ends the block's Live Activity from Timer state (`LiveActivityPlanner` decides what to
/// do; this only talks to ActivityKit). An activity can only be started while the app is in the foreground,
/// which is where every state change reaches this code. After a block ends in the background the activity stays
/// on screen with a finished countdown until the app next runs.
@MainActor
final class LiveActivityController {
    private var activity: Activity<PomoActivityAttributes>?
    private var current: LiveActivityContent?
    private var adopted = false

    func update(timer: TimerState, nowMs: Int64) async {
        adoptExisting()
        switch LiveActivityPlanner.plan(timer: timer, nowMs: nowMs, current: current) {
        case .none:
            break
        case let .start(content):
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(
                attributes: PomoActivityAttributes(),
                content: ActivityContent(state: content, staleDate: content.staleDate),
                pushType: nil
            )
            current = activity == nil ? nil : content
        case let .update(content):
            guard let activity else { current = nil; return }
            await activity.update(ActivityContent(state: content, staleDate: content.staleDate))
            current = content
        case .end:
            await activity?.end(nil, dismissalPolicy: .immediate)
            activity = nil
            current = nil
        }
    }

    /// An activity from an earlier launch keeps running: take it over, and end any extras.
    private func adoptExisting() {
        guard !adopted else { return }
        adopted = true
        let existing = Activity<PomoActivityAttributes>.activities
        guard let first = existing.first else { return }
        activity = first
        current = first.content.state
        for extra in existing.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
