import Foundation

/// Pure pagination-edge decisions for the conversation timeline window: whether a
/// freshly fetched page actually advanced the loaded window past its previous
/// oldest/newest message (a page that didn't move the edge means there is nothing
/// more in that direction). Extracted from `ConversationViewModel` so the decision
/// is independently testable, ahead of the TimelineStore split.
enum ConversationPaginationPolicy {
    static func movedOlder(
        previousOldestMessageId: String?,
        nextMessageIds: [String]
    ) -> Bool {
        guard let previousOldestMessageId else { return !nextMessageIds.isEmpty }
        guard let nextOldestMessageId = nextMessageIds.first else { return false }
        return nextOldestMessageId != previousOldestMessageId
    }

    static func movedNewer(
        previousNewestMessageId: String?,
        nextMessageIds: [String]
    ) -> Bool {
        guard let previousNewestMessageId else { return !nextMessageIds.isEmpty }
        guard let nextNewestMessageId = nextMessageIds.last else { return false }
        return nextNewestMessageId != previousNewestMessageId
    }
}
