#if os(iOS)
import ActivityKit
import Foundation

/// ActivityKit attributes for the block Live Activity. All state is in `ContentState`.
public struct PomoActivityAttributes: ActivityAttributes {
    public typealias ContentState = LiveActivityContent

    public init() {}
}
#endif
