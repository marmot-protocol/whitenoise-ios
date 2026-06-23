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
/// `recompute` folds the mirrored summary plus local optimistic diffs (and the
/// timeline's `deletedMessageIds` / local account id, both passed in) into UI
/// tallies. It does not rescan loaded timeline rows to rebuild server truth; the
/// only `MessageSemantics` classification here is for optimistic records created
/// by the local toggle path. The pure reconciliation that drops confirmed
/// optimistic placeholders lives in `ConversationReactionPolicy`. Sibling to
/// `ConversationMarkdownProjectionCache` / `ConversationMediaProjectionCache` —
/// another row-display projection peeled out of the view model ahead of the core
/// message mirror. The optimistic toggle's FFI + rollback orchestration stays in
/// the view model; only the state and the aggregation live here.
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

    /// All aggregated tallies (for full-recompute test hooks).
    var allTallies: [String: [ConversationViewModel.ReactionTally]] { talliesByTarget }

    /// Rebuild every per-target tally. Reserved for full projection refreshes or
    /// delete-state changes; live deltas should prefer `recompute(targets:…)` so
    /// they don't rescan unrelated targets (#380).
    @discardableResult
    func recompute(deletedMessageIds: Set<String>, me: String) -> Bool {
        var targets = Set(summariesByTarget.keys)
        targets.formUnion(optimisticRemovals.map(\.targetMessageIdHex))
        for record in optimisticRecords.values {
            guard case .reaction(let target) = MessageSemantics.classify(record) else { continue }
            targets.insert(target)
        }

        var result: [String: [ConversationViewModel.ReactionTally]] = [:]
        for target in targets where !target.isEmpty {
            let tallies = ConversationViewModel.reactionTallies(
                for: target,
                summary: summariesByTarget[target],
                optimisticRemovals: optimisticRemovals,
                optimisticRecords: optimisticRecords,
                deletedMessageIds: deletedMessageIds,
                me: me
            )
            if !tallies.isEmpty {
                result[target] = tallies
            }
        }
        guard talliesByTarget != result else { return false }
        talliesByTarget = result
        return true
    }

    /// Recompute only the supplied targets — used for live single-row projection
    /// updates and local optimistic toggles (#380).
    @discardableResult
    func recompute(targets: Set<String>, deletedMessageIds: Set<String>, me: String) -> Bool {
        guard !targets.isEmpty else { return false }
        var next = talliesByTarget
        for target in targets where !target.isEmpty {
            let tallies = ConversationViewModel.reactionTallies(
                for: target,
                summary: summariesByTarget[target],
                optimisticRemovals: optimisticRemovals,
                optimisticRecords: optimisticRecords,
                deletedMessageIds: deletedMessageIds,
                me: me
            )
            if tallies.isEmpty {
                next[target] = nil
            } else {
                next[target] = tallies
            }
        }
        guard talliesByTarget != next else { return false }
        talliesByTarget = next
        return true
    }
}
