import Foundation
import MarmotKit

/// One optimistic "un-react" placeholder: suppresses `sender` from a
/// target+emoji tally until the un-react lands server-side (#349).
nonisolated struct ReactionRemoval: Hashable {
    let targetMessageIdHex: String
    let emoji: String
    let sender: String
}

/// Pure reaction-overlay reconciliation for the conversation timeline: dropping
/// optimistic react / un-react placeholders once the authoritative server summary
/// confirms them. Extracted from `ConversationViewModel` so the subtle #47/#349
/// reconciliation is independently testable, ahead of the TimelineStore split.
enum ConversationReactionPolicy {
    nonisolated static func prunedConfirmedOptimisticReactions(
        _ records: [String: AppMessageRecordFfi],
        target: String,
        summary: TimelineReactionSummaryFfi,
        me: String
    ) -> [String: AppMessageRecordFfi] {
        guard !me.isEmpty else { return records }
        let confirmedEmoji = Set(
            summary.byEmoji
                .filter { $0.senders.contains(me) }
                .map(\.emoji)
        )
        guard !confirmedEmoji.isEmpty else { return records }
        return records.filter { _, record in
            guard record.sender == me,
                  confirmedEmoji.contains(record.plaintext),
                  case .reaction(let recordTarget) = MessageSemantics.classify(record),
                  recordTarget == target
            else { return true }
            return false
        }
    }

    /// Drop optimistic un-react placeholders that the server projection has now
    /// confirmed. A `ReactionRemoval` suppresses `me` from a target+emoji tally
    /// until the un-react lands server-side; once the authoritative summary for
    /// that target no longer lists `me` for the emoji, the removal is redundant
    /// and must be dropped (#349). Without this, the removal is retained for the
    /// conversation's lifetime — leaking on the MainActor rebuild hot path and,
    /// worse, silently subtracting `me` from a later *genuine* re-reaction once
    /// its own optimistic record is pruned. Mirrors
    /// `prunedConfirmedOptimisticReactions` for the remove side.
    nonisolated static func prunedConfirmedOptimisticReactionRemovals(
        _ removals: Set<ReactionRemoval>,
        target: String,
        summary: TimelineReactionSummaryFfi,
        me: String
    ) -> Set<ReactionRemoval> {
        guard !me.isEmpty else { return removals }
        // Emoji on this target the server summary still attributes to `me`.
        // A removal for one of these is NOT yet confirmed — keep suppressing.
        let stillMineEmoji = Set(
            summary.byEmoji
                .filter { $0.senders.contains(me) }
                .map(\.emoji)
        )
        return removals.filter { removal in
            guard removal.targetMessageIdHex == target, removal.sender == me
            else { return true }
            // Confirmed when the summary no longer lists me for this emoji.
            return stillMineEmoji.contains(removal.emoji)
        }
    }
}
