import Foundation

/// Pure pagination-edge decisions for the conversation timeline window: whether a
/// freshly fetched page actually advanced the loaded window past its previous
/// oldest/newest message (a page that didn't move the edge means there is nothing
/// more in that direction). Extracted from `ConversationViewModel` so the decision
/// is independently testable, ahead of the TimelineStore split.
enum ConversationPaginationPolicy {
    /// A tail refresh re-reads only the newest rows, so its forward edge is
    /// authoritative only when the window had nothing to drop from the page.
    /// Narrowing a stale-open edge is what lets a fully loaded tail stop
    /// advertising newer rows that do not exist; keeping it open after a
    /// dropped page avoids claiming a tail the window never ingested.
    static func forwardEdgeAfterTailRefresh(
        currentHasMoreAfter: Bool,
        pageHasMoreAfter: Bool,
        droppedNewerRecords: Bool
    ) -> Bool {
        guard currentHasMoreAfter else { return pageHasMoreAfter }
        return droppedNewerRecords ? true : pageHasMoreAfter
    }

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
