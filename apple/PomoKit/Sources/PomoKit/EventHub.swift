import Foundation
import PomoCoreFFI

/// Fans the Core's single listener out to any number of subscribers.
final class EventHub: PomoListener, @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: @Sendable (CoreEvent) -> Void] = [:]

    func subscribe(_ handler: @escaping @Sendable (CoreEvent) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { subscribers[id] = handler }
        return id
    }

    func unsubscribe(_ id: UUID) {
        lock.withLock { _ = subscribers.removeValue(forKey: id) }
    }

    func onEvent(event: CoreEvent) {
        let handlers = lock.withLock { Array(subscribers.values) }
        for h in handlers { h(event) }
    }
}
