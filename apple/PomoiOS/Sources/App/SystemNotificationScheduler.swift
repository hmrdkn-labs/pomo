import Foundation
import PomoLive
import UserNotifications

/// Schedules the block-end notification with `UNUserNotificationCenter`. The request is built from the block's
/// absolute end time, so it fires whether or not the app is running.
struct SystemNotificationScheduler: NotificationScheduling {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// The request for `notification` as seen at `now`. A time already past fires in one second.
    static func request(for n: BlockEndNotification, now: Date = Date()) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        content.threadIdentifier = "pomo.blocks"
        content.userInfo = ["block_id": n.blockId]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, n.fireDate.timeIntervalSince(now)), repeats: false)
        return UNNotificationRequest(identifier: BlockEndNotification.identifier, content: content, trigger: trigger)
    }

    func schedule(_ notification: BlockEndNotification) async {
        // Same identifier: replaces the pending request.
        try? await UNUserNotificationCenter.current().add(Self.request(for: notification))
    }

    func cancel() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [BlockEndNotification.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [BlockEndNotification.identifier])
    }
}

/// While the app is open it already shows the Timer, so a block-end notification only plays its sound.
final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.sound]
    }
}
