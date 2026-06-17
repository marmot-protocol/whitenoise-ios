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

    static func chatList(_ sub: ChatListSubscription) -> AsyncStream<ChatListRowFfi> {
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

    static func chatListUpdates(_ sub: ChatListSubscription) -> AsyncStream<ChatListSubscriptionUpdateFfi> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled, let next = await sub.nextUpdate() {
                    continuation.yield(next)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func timelineMessages(_ sub: TimelineMessagesSubscription) -> AsyncStream<TimelinePageFfi> {
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

    static func notifications(_ sub: NotificationsSubscription) -> AsyncStream<NotificationUpdateFfi> {
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
