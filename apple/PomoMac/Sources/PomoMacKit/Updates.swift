import AppKit
import Sparkle

/// Daily, opt-out update check (Sparkle 2): fetches the appcast from GitHub and installs signed updates in place.
/// Nothing runs until `start()`, which only the real app calls, so tests never start an updater.
@MainActor
public enum Updates {
    private static let reminders = Reminders()

    /// Nil until `start()`, and stays nil for a build without a Sparkle key (ad hoc builds).
    public private(set) static var controller: SPUStandardUpdaterController?

    /// Starts the updater when the bundle carries a Sparkle public key; Info.plist sets the feed and the daily interval.
    public static func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: reminders)
    }

    /// Mirrors Sparkle's own setting, which it persists in user defaults.
    public static var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// A menu bar app has no Dock icon to badge, so a background check that finds an update brings its window
    /// to the front instead of leaving it behind other apps.
    private final class Reminders: NSObject, SPUStandardUserDriverDelegate {
        var supportsGentleScheduledUpdateReminders: Bool { true }

        func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                       state: SPUUserUpdateState) {
            // Sparkle calls its user driver delegate on the main thread.
            if handleShowingUpdate { MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) } }
        }
    }
}
