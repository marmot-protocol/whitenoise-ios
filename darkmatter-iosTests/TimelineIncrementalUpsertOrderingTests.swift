import Foundation
import Testing
@testable import darkmatter_ios
@testable import MarmotKit

/// #202 — the incremental single-row upsert path must produce the same row
/// order as a full rebuild. The old `upsertTimelineItem` binary-searched the
/// already reply-normalized (non-monotonic) `timeline` array, which returns an
/// arbitrary index and could place a row out of chronological order or break
/// the "reply sits directly under its parent" grouping until the next full
/// `rebuildTimeline()`. Both paths now funnel through
/// `ConversationViewModel.normalizedTimeline(from:replyTargetId:)`, so they
/// can never diverge.
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

    /// A reply (t=20) to a parent (t=10) is pulled up out of timestamp order to
    /// sit directly under its parent, ahead of later messages (t=11, t=12).
    @Test func fullRebuildPullsReplyUnderParent() {
        let parent = TimelineItem.message(record(id: hexId(0x10), timestamp: 10))
        let reply = TimelineItem.message(record(id: hexId(0x20), timestamp: 20))
        let m11 = TimelineItem.message(record(id: hexId(0x11), timestamp: 11))
        let m12 = TimelineItem.message(record(id: hexId(0x12), timestamp: 12))
        let replies = [reply.messageIdHex: parent.messageIdHex]

        let ordered = rebuild([m12, reply, parent, m11], replies: replies)

        #expect(ordered.map(\.timestamp) == [10, 20, 11, 12])
    }

    /// The crux of #202: take the reply-normalized timeline `[10, 20, 11, 12]`
    /// and incrementally upsert a new non-reply at t=10.5. The incremental
    /// result must equal a full rebuild from the raw set, i.e. `[10, 20, 10.5,
    /// 11, 12]` — NOT the divergent `[10, 10.5, 20, 11, 12]` the old binary
    /// search produced.
    @Test func incrementalUpsertMatchesFullRebuildWithOutOfOrderReply() {
        let parent = TimelineItem.message(record(id: hexId(0x10), timestamp: 10))
        let reply = TimelineItem.message(record(id: hexId(0x20), timestamp: 20))
        let m11 = TimelineItem.message(record(id: hexId(0x11), timestamp: 11))
        let m12 = TimelineItem.message(record(id: hexId(0x12), timestamp: 12))
        let inserted = TimelineItem.message(record(id: hexId(0x105), timestamp: 1005))
        let replies = [reply.messageIdHex: parent.messageIdHex]

        // Current displayed (reply-normalized) timeline.
        let normalized = rebuild([parent, reply, m11, m12], replies: replies)
        #expect(normalized.map(\.timestamp) == [10, 20, 11, 12])

        // Incremental upsert path: append the new row to the *normalized*
        // (non-monotonic) array, then renormalize — exactly what
        // upsertTimelineItem now does.
        let incremental = rebuild(normalized + [inserted], replies: replies)

        // Full rebuild from the raw, unsorted set.
        let fullRebuild = rebuild([m12, inserted, reply, parent, m11], replies: replies)

        #expect(incremental == fullRebuild)
        #expect(incremental.map(\.timestamp) == [10, 20, 1005, 11, 12])
    }

    /// Upserting the parent of a deferred reply must still group the reply
    /// directly beneath it, regardless of insertion order.
    @Test func incrementalUpsertOfParentRegroupsReply() {
        let parent = TimelineItem.message(record(id: hexId(0x10), timestamp: 10))
        let reply = TimelineItem.message(record(id: hexId(0x20), timestamp: 20))
        let later = TimelineItem.message(record(id: hexId(0x30), timestamp: 30))
        let replies = [reply.messageIdHex: parent.messageIdHex]

        // Timeline before the parent arrives: reply + a later message.
        let beforeParent = rebuild([reply, later], replies: replies)

        // Upsert the parent.
        let incremental = rebuild(beforeParent + [parent], replies: replies)
        let fullRebuild = rebuild([later, reply, parent], replies: replies)

        #expect(incremental == fullRebuild)
        #expect(incremental.map(\.timestamp) == [10, 20, 30])
    }
}
