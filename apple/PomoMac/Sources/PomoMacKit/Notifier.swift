import Foundation
import PomoUI
import UserNotifications

/// Local notification at block end. Only works inside an app bundle; elsewhere it is a no-op.
@MainActor
public final class Notifier {
    private var requested = false
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    public init() {}

    /// Asks for permission the first time it is called (first start of a block).
    public func requestAuthorizationIfNeeded() {
        guard available, !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func blockEnded(_ notice: BlockEndNotice) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        switch notice.kind {
        case .focus:
            content.title = "Focus block complete"
            content.body = notice.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Time for a break."
        case .shortBreak, .longBreak:
            content.title = "\(notice.kind.title) over"
            content.body = "Ready for the next focus block."
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
