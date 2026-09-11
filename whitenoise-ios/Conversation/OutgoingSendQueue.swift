import Foundation

/// Serializes the publish half of one conversation's outgoing sends.
///
/// The composer parks its optimistic row, claims a slot here, and is free
/// again — so a second Send is never blocked behind the first. Queueing rather
/// than racing is what keeps the timeline and the relays agreeing: two
/// concurrent `sendText` calls would reach the relays in whatever order their
/// round-trips happened to finish, while the rows above them stayed put. A slot
/// is claimed in the same synchronous step that parks the row, so messages
/// publish in the order their rows appeared — which is press order except for
/// sends whose markdown parses overlap.
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
