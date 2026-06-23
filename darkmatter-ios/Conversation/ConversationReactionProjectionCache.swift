import Foundation
import MarmotKit

/// Per-target reaction tally cache for the conversation timeline. Owns the three
/// reaction inputs and the aggregated output:
///
/// - `summariesByTarget` — the authoritative server reaction summary mirrored
///   from each timeline row at ingest.
/// - `optimisticRecords` — synthesized kind-7 reaction events for the local
///   "react" optimistic overlay, keyed by their own temporary id.
/// - `optimisticRemovals` — `ReactionRemoval` placeholders suppressing `me` from
///   a target+emoji tally until an "un-react" lands server-side (#349).
/// - `talliesByTarget` — the aggregated `[ReactionTally]` per target message.
///
/// `recompute` folds the three inputs (plus the timeline's `deletedMessageIds`
/// and the local account id, both passed in) into the tallies. The pure
/// reconciliation that drops confirmed optimistic placeholders lives in
/// `ConversationReactionPolicy`. Sibling to `ConversationMarkdownProjectionCache`
/// / `ConversationMediaProjectionCache` — another row-display projection peeled
/// out of the view model ahead of the core message mirror. The optimistic
/// toggle's FFI + rollback orchestration stays in the view model; only the state
/// and the aggregation live here.
@MainActor
final class ConversationReactionProjectionCache {
    private var summariesByTarget: [String: TimelineReactionSummaryFfi] = [:]
    private var optimisticRecords: [String: AppMessageRecordFfi] = [:]
    private var optimisticRemovals: Set<ReactionRemoval> = []
    private var talliesByTarget: [String: [ConversationViewModel.ReactionTally]] = [:]

    // MARK: Read

    func tallies(forMessageId messageIdHex: String) -> [ConversationViewModel.ReactionTally] {
        talliesByTarget[messageIdHex] ?? []
    }

    // MARK: Server summary (ingest write-path)

    func setSummary(_ summary: TimelineReactionSummaryFfi, forMessageId messageIdHex: String) {
        summariesByTarget[messageIdHex] = summary
    }

    func removeSummary(forMessageId messageIdHex: String) {
        summariesByTarget[messageIdHex] = nil
    }

    /// Drop optimistic react / un-react placeholders the server summary for
    /// `target` has now confirmed (#47/#349).
    func pruneConfirmedOptimistic(target: String, summary: TimelineReactionSummaryFfi, me: String) {
        optimisticRecords = ConversationReactionPolicy.prunedConfirmedOptimisticReactions(
            optimisticRecords,
            target: target,
            summary: summary,
            me: me
        )
        optimisticRemovals = ConversationReactionPolicy.prunedConfirmedOptimisticReactionRemovals(
            optimisticRemovals,
            target: target,
            summary: summary,
            me: me
        )
    }

    // MARK: Optimistic overlay (toggle write-path)

    var hasOptimistic: Bool { !optimisticRecords.isEmpty || !optimisticRemovals.isEmpty }

    func removeAllOptimistic() {
        optimisticRecords.removeAll()
        optimisticRemovals.removeAll()
    }

    func insertRemoval(_ removal: ReactionRemoval) {
        optimisticRemovals.insert(removal)
    }

    @discardableResult
    func removeRemoval(_ removal: ReactionRemoval) -> Bool {
        optimisticRemovals.remove(removal) != nil
    }

    func setRecord(_ record: AppMessageRecordFfi, forKey key: String) {
        optimisticRecords[key] = record
    }

    @discardableResult
    func removeRecord(forKey key: String) -> AppMessageRecordFfi? {
        optimisticRecords.removeValue(forKey: key)
    }

    func restoreRecords(_ records: [String: AppMessageRecordFfi]) {
        for (key, record) in records {
            optimisticRecords[key] = record
        }
    }

    /// Removes (and returns) this sender's optimistic react records for a
    /// target+emoji, so an "un-react" can roll them back on failure.
    func removeMatchingRecords(target: String, emoji: String, sender: String) -> [String: AppMessageRecordFfi] {
        var removed: [String: AppMessageRecordFfi] = [:]
        for (key, record) in optimisticRecords {
            guard record.sender == sender, record.plaintext == emoji,
                  case .reaction(let recordTarget) = MessageSemantics.classify(record),
                  recordTarget == target
            else { continue }
            removed[key] = record
        }
        for key in removed.keys { optimisticRecords.removeValue(forKey: key) }
        return removed
    }

    // MARK: Aggregation

    @discardableResult
    func recompute(deletedMessageIds: Set<String>, me: String) -> Bool {
        var byTarget: [String: [String: Set<String>]] = [:]

        for (target, summary) in summariesByTarget {
            for reaction in summary.byEmoji where !reaction.emoji.isEmpty {
                var emojis = byTarget[target] ?? [:]
                emojis[reaction.emoji] = Set(reaction.senders)
                byTarget[target] = emojis
            }
        }

        for removal in optimisticRemovals {
            guard var emojis = byTarget[removal.targetMessageIdHex],
                  var senders = emojis[removal.emoji]
            else { continue }
            senders.remove(removal.sender)
            emojis[removal.emoji] = senders
            byTarget[removal.targetMessageIdHex] = emojis
        }

        let ordered: [AppMessageRecordFfi] = optimisticRecords.values
            .sorted { $0.recordedAt < $1.recordedAt }
        for record in ordered {
            guard case .reaction(let target) = MessageSemantics.classify(record) else { continue }
            // Un-react: the reaction event was deleted (kind-5 on its id).
            if !record.messageIdHex.isEmpty, deletedMessageIds.contains(record.messageIdHex) {
                continue
            }
            let emoji = record.plaintext
            var emojis: [String: Set<String>] = byTarget[target] ?? [:]
            if !emoji.isEmpty {
                var senders: Set<String> = emojis[emoji] ?? []
                senders.insert(record.sender)
                emojis[emoji] = senders
            }
            byTarget[target] = emojis
        }

        var result: [String: [ConversationViewModel.ReactionTally]] = [:]
        for (target, emojis) in byTarget {
            var tallies: [ConversationViewModel.ReactionTally] = []
            for (emoji, senders) in emojis where !senders.isEmpty {
                tallies.append(ConversationViewModel.ReactionTally(emoji: emoji, count: senders.count, mine: senders.contains(me)))
            }
            guard !tallies.isEmpty else { continue }
            tallies.sort { lhs, rhs in
                lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
            }
            result[target] = tallies
        }
        guard talliesByTarget != result else { return false }
        talliesByTarget = result
        return true
    }
}
