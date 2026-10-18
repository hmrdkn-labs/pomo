import Foundation
import Observation

/// User preferences kept in `UserDefaults`. Durations are applied when this app issues `start` commands.
@MainActor @Observable
public final class PomoSettings {
    public enum Key {
        public static let focusMinutes = "focusMinutes"
        public static let shortBreakMinutes = "shortBreakMinutes"
        public static let longBreakMinutes = "longBreakMinutes"
        public static let longBreakEvery = "longBreakEvery"
        public static let showDockIcon = "showDockIcon"
    }

    private let defaults: UserDefaults

    public var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: Key.focusMinutes) } }
    public var shortBreakMinutes: Int { didSet { defaults.set(shortBreakMinutes, forKey: Key.shortBreakMinutes) } }
    public var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: Key.longBreakMinutes) } }
    public var longBreakEvery: Int { didSet { defaults.set(longBreakEvery, forKey: Key.longBreakEvery) } }
    public var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func int(_ key: String, _ fallback: Int) -> Int {
            let v = defaults.integer(forKey: key)
            return v > 0 ? v : fallback
        }
        focusMinutes = int(Key.focusMinutes, 25)
        shortBreakMinutes = int(Key.shortBreakMinutes, 5)
        longBreakMinutes = int(Key.longBreakMinutes, 15)
        longBreakEvery = int(Key.longBreakEvery, 4)
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
    }

    public func minutes(for kind: Kind) -> Int {
        switch kind {
        case .focus: focusMinutes
        case .shortBreak: shortBreakMinutes
        case .longBreak: longBreakMinutes
        }
    }

    public func plannedMs(for kind: Kind) -> Int64 { Int64(max(1, minutes(for: kind))) * 60_000 }
}
