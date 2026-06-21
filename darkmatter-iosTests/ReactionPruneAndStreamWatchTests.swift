import Testing
import Foundation
@testable import darkmatter_ios
@testable import MarmotKit

/// #47 — optimistic reaction placeholders must be pruned once the server
/// projection confirms them, so reactionRecords doesn't grow over a session.
struct OptimisticReactionPruneTests {
    private let me = String(repeating: "1", count: 64)
    private let target = String(repeating: "a", count: 64)

    private func optimisticReaction(emoji: String, sender: String, target: String) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: "optimistic-\(emoji)-\(sender)",
            direction: "sent",
            groupIdHex: String(repeating: "c", count: 64),
            sender: sender,
            plaintext: emoji,
            kind: MessageSemantics.kindReaction,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])],
            recordedAt: 1,
            receivedAt: 1
        )
    }

    @Test func dropsOptimisticReactionConfirmedByServerSummary() {
        let record = optimisticReaction(emoji: "👍", sender: me, target: target)
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", senders: [me])],
            userReactions: []
        )
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactions(
            [record.messageIdHex: record], target: target, summary: summary, me: me
        )
        #expect(pruned.isEmpty)
    }

    @Test func keepsOptimisticReactionNotYetInSummary() {
        let record = optimisticReaction(emoji: "👍", sender: me, target: target)
        let summary = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactions(
            [record.messageIdHex: record], target: target, summary: summary, me: me
        )
        #expect(pruned.count == 1)
    }

    @Test func keepsReactionsForADifferentTargetOrEmoji() {
        let record = optimisticReaction(emoji: "👍", sender: me, target: target)
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", senders: [me])],
            userReactions: []
        )
        // Summary belongs to a different target — record must be kept.
        let otherTarget = String(repeating: "b", count: 64)
        #expect(ConversationViewModel.prunedConfirmedOptimisticReactions(
            [record.messageIdHex: record], target: otherTarget, summary: summary, me: me
        ).count == 1)
        // Summary confirms a different emoji — record must be kept.
        let heart = optimisticReaction(emoji: "❤️", sender: me, target: target)
        #expect(ConversationViewModel.prunedConfirmedOptimisticReactions(
            [heart.messageIdHex: heart], target: target, summary: summary, me: me
        ).count == 1)
    }
}

/// #349 — the remove-side analog of #47. An optimistic `ReactionRemoval`
/// suppresses `me` from a target+emoji tally until the un-react lands
/// server-side. Once the authoritative summary for that target no longer
/// lists `me` for the emoji the removal is confirmed and must be dropped,
/// otherwise it leaks for the conversation's lifetime and can silently
/// subtract a later genuine re-reaction.
struct OptimisticReactionRemovalPruneTests {
    private let me = String(repeating: "1", count: 64)
    private let other = String(repeating: "2", count: 64)
    private let target = String(repeating: "a", count: 64)

    private func removal(emoji: String, sender: String, target: String) -> ConversationViewModel.ReactionRemoval {
        ConversationViewModel.ReactionRemoval(
            targetMessageIdHex: target,
            emoji: emoji,
            sender: sender
        )
    }

    @Test func dropsRemovalWhenServerSummaryNoLongerListsMe() {
        // Un-react confirmed: the summary for this target has no entry for me.
        let summary = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [removal(emoji: "❤️", sender: me, target: target)],
            target: target, summary: summary, me: me
        )
        #expect(pruned.isEmpty)
    }

    @Test func dropsRemovalWhenOtherSendersRemainButMeDoesNot() {
        // Someone else still reacts ❤️ on this target, but me does not —
        // my un-react is still confirmed, so the removal is dropped.
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "❤️", senders: [other])],
            userReactions: []
        )
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [removal(emoji: "❤️", sender: me, target: target)],
            target: target, summary: summary, me: me
        )
        #expect(pruned.isEmpty)
    }

    @Test func keepsRemovalWhileServerSummaryStillListsMe() {
        // Un-react not yet propagated — summary still attributes ❤️ to me, so
        // keep suppressing it optimistically.
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "❤️", senders: [me])],
            userReactions: []
        )
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [removal(emoji: "❤️", sender: me, target: target)],
            target: target, summary: summary, me: me
        )
        #expect(pruned.count == 1)
    }

    @Test func leavesRemovalsForADifferentTargetUntouched() {
        // The reconciler runs per incoming-record target; a removal for another
        // target must never be dropped by this target's summary.
        let otherTarget = String(repeating: "b", count: 64)
        let summary = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [removal(emoji: "❤️", sender: me, target: otherTarget)],
            target: target, summary: summary, me: me
        )
        #expect(pruned.count == 1)
    }

    @Test func prunesOnlyConfirmedEmojiOnTheSameTarget() {
        // ❤️ confirmed (no me in summary) → dropped; 👍 still mine → kept.
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", senders: [me])],
            userReactions: []
        )
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            [
                removal(emoji: "❤️", sender: me, target: target),
                removal(emoji: "👍", sender: me, target: target),
            ],
            target: target, summary: summary, me: me
        )
        #expect(pruned == [removal(emoji: "👍", sender: me, target: target)])
    }

    @Test func returnsInputUnchangedWhenMeIsEmpty() {
        let summary = TimelineReactionSummaryFfi(byEmoji: [], userReactions: [])
        let input: Set<ConversationViewModel.ReactionRemoval> = [removal(emoji: "❤️", sender: me, target: target)]
        let pruned = ConversationViewModel.prunedConfirmedOptimisticReactionRemovals(
            input, target: target, summary: summary, me: ""
        )
        #expect(pruned == input)
    }
}

/// #48 — a concurrent "latest" (nil stream id) watch must be guarded so it can't
/// race past the post-await duplicate check and open an orphaned subscription.
struct StreamWatchRaceGuardTests {

    @Test func startWatchingGuardsConcurrentLatestWatch() {
        #expect(!AgentStreamWatchAdmission.canStart(
            streamIdHex: nil,
            activeStreamIds: [],
            latestStreamWatchInFlight: true
        ))
        #expect(AgentStreamWatchAdmission.canStart(
            streamIdHex: nil,
            activeStreamIds: [],
            latestStreamWatchInFlight: false
        ))
        #expect(!AgentStreamWatchAdmission.canStart(
            streamIdHex: "stream-a",
            activeStreamIds: ["stream-a"],
            latestStreamWatchInFlight: false
        ))
        #expect(AgentStreamWatchAdmission.canStart(
            streamIdHex: "stream-b",
            activeStreamIds: ["stream-a"],
            latestStreamWatchInFlight: true
        ))
    }
}
