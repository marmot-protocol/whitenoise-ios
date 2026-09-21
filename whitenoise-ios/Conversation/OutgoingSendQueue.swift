import Foundation

/// Orders local admissions so draft revisions and media submissions keep Send order.
/// MDK owns publication after acceptance; the next text send need not await relays.
@MainActor
final class OutgoingSendQueue {
    private var tail: Task<Void, Never>?

    /// Claims the next slot synchronously and returns the task that will run
    /// `operation` once every send queued before it has finished. The work is
    /// unstructured, so a caller that goes away mid-flight still gets its
    /// message published.
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let predecessor = tail
        let task = Task { @MainActor in
            // A failed predecessor releases its successor just like a
            // successful one; it only leaves a failed row behind it.
            await predecessor?.value
            await operation()
        }
        tail = task
        return task
    }
}
