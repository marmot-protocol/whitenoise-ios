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
/// - `detailsByTarget` — sender-level reactions per target message, from which
///   the bubble tallies and reaction-details sheet are both derived.
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
    private var detailsByTarget: [String: ConversationViewModel.ReactionDetails] = [:]

    // MARK: Read

    func tallies(forMessageId messageIdHex: String) -> [ConversationViewModel.ReactionTally] {
        detailsByTarget[messageIdHex]?.tallies ?? []
    }

    func details(forMessageId messageIdHex: String) -> ConversationViewModel.ReactionDetails {
        detailsByTarget[messageIdHex] ?? ConversationViewModel.ReactionDetails(groups: [])
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

    func installPrepared(_ value: ConversationReactionsFfi, target: String, me: String) {
        let mine = Set(value.items.filter(\.viewerReacted).map(\.emoji))
        optimisticRecords = optimisticRecords.filter { _, record in
            guard record.sender == me, mine.contains(record.plaintext),
                  case .reaction(let id) = MessageSemantics.classify(record), id == target else { return true }
            return false
        }
        optimisticRemovals = optimisticRemovals.filter {
            $0.targetMessageIdHex != target || $0.sender != me || mine.contains($0.emoji)
        }
    }

    func preparedDetails(_ value: ConversationReactionsFfi, target: String, me: String) -> ConversationViewModel.ReactionDetails {
        var groups = value.items.map {
            ConversationViewModel.ReactionDetails.EmojiGroup(emoji: $0.emoji, senders: $0.reactors,
                mine: $0.viewerReacted, totalCount: Int(clamping: $0.count))
        }
        let additions = Set(optimisticRecords.values.compactMap { record -> String? in
            guard record.sender == me, case .reaction(let id) = MessageSemantics.classify(record), id == target else { return nil }
            return record.plaintext
        })
        for emoji in additions where !groups.contains(where: { $0.emoji == emoji }) {
            groups.append(.init(emoji: emoji, senders: [], mine: false, totalCount: 0))
        }
        groups = groups.compactMap { group in
            let removed = optimisticRemovals.contains { $0.targetMessageIdHex == target && $0.emoji == group.emoji && $0.sender == me }
            let mine = removed ? false : (group.mine || additions.contains(group.emoji))
            let count = max(0, group.count + (mine ? 1 : 0) - (group.mine ? 1 : 0))
            guard count > 0 else { return nil }
            var senders = group.senders.filter { $0 != me }
            if mine && !me.isEmpty { senders.append(me) }
            return .init(emoji: group.emoji, senders: senders, mine: mine, totalCount: count)
        }
        let original = value.items.reduce(0) { $0 + Int(clamping: $1.count) }
        let adjusted = Int(clamping: value.totalCount) + groups.reduce(0) { $0 + $1.count } - original
        return .init(groups: groups, omittedKinds: value.omittedKinds, totalCount: max(0, adjusted))
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
    /// target, so an "un-react" can roll them back on failure.
    func removeMatchingRecords(target: String, sender: String) -> [String: AppMessageRecordFfi] {
        var removed: [String: AppMessageRecordFfi] = [:]
        for (key, record) in optimisticRecords {
            guard record.sender == sender,
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
    var allTallies: [String: [ConversationViewModel.ReactionTally]] {
        detailsByTarget.mapValues(\.tallies)
    }

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

        var result: [String: ConversationViewModel.ReactionDetails] = [:]
        for target in targets where !target.isEmpty {
            let details = ConversationViewModel.reactionDetails(
                for: target,
                summary: summariesByTarget[target],
                optimisticRemovals: optimisticRemovals,
                optimisticRecords: optimisticRecords,
                deletedMessageIds: deletedMessageIds,
                me: me
            )
            if !details.groups.isEmpty {
                result[target] = details
            }
        }
        guard detailsByTarget != result else { return false }
        detailsByTarget = result
        return true
    }

    /// Recompute only the supplied targets — used for live single-row projection
    /// updates and local optimistic toggles (#380).
    @discardableResult
    func recompute(targets: Set<String>, deletedMessageIds: Set<String>, me: String) -> Bool {
        guard !targets.isEmpty else { return false }
        var next = detailsByTarget
        for target in targets where !target.isEmpty {
            let details = ConversationViewModel.reactionDetails(
                for: target,
                summary: summariesByTarget[target],
                optimisticRemovals: optimisticRemovals,
                optimisticRecords: optimisticRecords,
                deletedMessageIds: deletedMessageIds,
                me: me
            )
            if details.groups.isEmpty {
                next[target] = nil
            } else {
                next[target] = details
            }
        }
        guard detailsByTarget != next else { return false }
        detailsByTarget = next
        return true
    }
}
