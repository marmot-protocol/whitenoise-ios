import Foundation
import Testing
@testable import darkmatter_ios
@testable import MarmotKit

/// #202 — the incremental single-row upsert path must produce the same row
/// order as a full rebuild. The old `upsertTimelineItem` binary-searched the
/// already reply-normalized `timeline` array. That array is *not* monotonic:
/// `normalizedReplyOrdering` pulls a reply that sorts *before* its parent
/// down to sit directly under that parent, leaving the array out of timestamp
/// order. Binary search over a non-monotonic array returns an arbitrary index,
/// so a single-row upsert could land at the wrong position and survive the
/// subsequent re-normalization until the next full `rebuildTimeline()`.
///
/// Both paths now funnel through
/// `ConversationViewModel.normalizedTimeline(from:replyTargetId:)`
/// (sort, then `normalizedReplyOrdering`), so they can never diverge.
struct TimelineIncrementalUpsertOrderingTests {
    private func hexId(_ n: Int) -> String {
        String(format: "%064x", n)
    }

    private func record(id: String, timestamp: UInt64) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: id,
            direction: "received",
            groupIdHex: String(repeating: "c", count: 64),
            sender: String(repeating: "b", count: 64),
            plaintext: "hi",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: timestamp,
            // receivedAt == 0 so sortTimestamp() == recordedAt (no clamping)
            receivedAt: 0
        )
    }

    /// Reconstructs the canonical order from a raw, unsorted row set.
    private func rebuild(
        _ items: [TimelineItem],
        replies: [String: String]
    ) -> [TimelineItem] {
        ConversationViewModel.normalizedTimeline(
            from: items,
            replyTargetId: { replies[$0.messageIdHex] }
        )
    }

    /// A reply (t=10) whose parent (t=20) sorts *after* it is pulled down to sit
    /// directly under its parent, producing a deliberately non-monotonic order:
    /// `[20, 10, 30]`. This is the array shape that breaks a naive binary search.
    @Test func fullRebuildPullsReplyUnderParent() {
        let reply = TimelineItem.message(record(id: hexId(0x10), timestamp: 10))
        let parent = TimelineItem.message(record(id: hexId(0x20), timestamp: 20))
        let m30 = TimelineItem.message(record(id: hexId(0x30), timestamp: 30))
        let replies = [reply.messageIdHex: parent.messageIdHex]

        let ordered = rebuild([m30, reply, parent], replies: replies)

        // reply (10) sits directly under its parent (20), out of timestamp order.
        #expect(ordered.map(\.timestamp) == [20, 10, 30])
    }

    /// The crux of #202: a reply-normalized timeline is non-monotonic, so an
    /// incremental upsert that binary-searches it lands in the wrong place.
    ///
    /// Normalized timeline: `[15, 20, 10, 25]` — reply (t=10) pulled down under
    /// its parent (t=20). Upserting a new non-reply at t=11 must match a full
    /// rebuild, i.e. `[11, 15, 20, 10, 25]`. The old binary search produced the
    /// divergent `[15, 20, 10, 11, 25]`.
    @Test func incrementalUpsertMatchesFullRebuildWithOutOfOrderReply() {
        let reply = TimelineItem.message(record(id: hexId(0x10), timestamp: 10))
        let m15 = TimelineItem.message(record(id: hexId(0x15), timestamp: 15))
        let parent = TimelineItem.message(record(id: hexId(0x20), timestamp: 20))
        let m25 = TimelineItem.message(record(id: hexId(0x25), timestamp: 25))
        let inserted = TimelineItem.message(record(id: hexId(0x11), timestamp: 11))
        let replies = [reply.messageIdHex: parent.messageIdHex]

        // Current displayed (reply-normalized, non-monotonic) timeline.
        let normalized = rebuild([reply, m15, parent, m25], replies: replies)
        #expect(normalized.map(\.timestamp) == [15, 20, 10, 25])

        // Incremental upsert path: append the new row to the *normalized*
        // (non-monotonic) array, then renormalize — exactly what
        // upsertTimelineItem now does.
        let incremental = rebuild(normalized + [inserted], replies: replies)

        // Full rebuild from the raw, unsorted set.
        let fullRebuild = rebuild([m25, inserted, reply, parent, m15], replies: replies)

        #expect(incremental == fullRebuild)
        #expect(incremental.map(\.timestamp) == [11, 15, 20, 10, 25])
    }

    /// Upserting the parent of a reply that arrived first must group that reply
    /// directly beneath the parent, regardless of insertion order.
    @Test func incrementalUpsertOfParentRegroupsReply() {
        let reply = TimelineItem.message(record(id: hexId(0x10), timestamp: 10))
        let parent = TimelineItem.message(record(id: hexId(0x20), timestamp: 20))
        let m30 = TimelineItem.message(record(id: hexId(0x30), timestamp: 30))
        let replies = [reply.messageIdHex: parent.messageIdHex]

        // Timeline before the parent arrives: the reply has no parent in the set
        // yet, so it stays in timestamp order alongside a later message.
        let beforeParent = rebuild([reply, m30], replies: replies)
        #expect(beforeParent.map(\.timestamp) == [10, 30])

        // Upsert the parent: the reply is now regrouped directly beneath it.
        let incremental = rebuild(beforeParent + [parent], replies: replies)
        let fullRebuild = rebuild([m30, reply, parent], replies: replies)

        #expect(incremental == fullRebuild)
        #expect(incremental.map(\.timestamp) == [20, 10, 30])
    }
}
