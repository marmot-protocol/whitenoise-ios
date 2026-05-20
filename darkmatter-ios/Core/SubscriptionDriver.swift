import Foundation
import MarmotKit

/// Adapter helpers that turn the UniFFI subscription objects into
/// `AsyncStream`s the SwiftUI view models can consume in `.task` modifiers.
enum SubscriptionDriver {

    static func chats(_ sub: ChatsSubscription) -> AsyncStream<AppGroupRecordFfi> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled, let next = await sub.next() {
                    continuation.yield(next)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func messages(_ sub: MessagesSubscription) -> AsyncStream<MessageUpdateFfi> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled, let next = await sub.next() {
                    continuation.yield(next)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func groupState(_ sub: GroupStateSubscription) -> AsyncStream<AppGroupRecordFfi> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled, let next = await sub.next() {
                    continuation.yield(next)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func events(_ sub: EventsSubscription) -> AsyncStream<MarmotEventFfi> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled, let next = await sub.next() {
                    continuation.yield(next)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
