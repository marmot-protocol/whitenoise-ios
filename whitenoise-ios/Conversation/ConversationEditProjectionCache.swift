import Foundation
import MarmotKit

/// Resolves kind-1009 edit events into the body shown by their original
/// message row. Edit events remain durable timeline records, but are never
/// rendered as separate user-facing bubbles.
@MainActor
final class ConversationEditProjectionCache {
    private struct StoredEdit {
        let record: AppMessageRecordFfi
        let targetMessageIdHex: String
        let isUsable: Bool
    }

    private struct OptimisticEdit {
        let sender: String
        let plaintext: String
        let contentTokens: MarkdownDocumentFfi
    }

    private var preparedSummaries: [String: TimelineEditSummaryFfi] = [:]
    private var preparedIDs: Set<String> = []

    private var editsById: [String: StoredEdit] = [:]
    private var editIdsByTarget: [String: Set<String>] = [:]
    private var optimisticByTarget: [String: OptimisticEdit] = [:]

    var hasOptimistic: Bool { !optimisticByTarget.isEmpty }

    func setPreparedRecord(_ record: AppMessageRecordFfi, edit: TimelineEditSummaryFfi?, deleted: Bool) {
        preparedIDs.insert(record.messageIdHex)
        preparedSummaries[record.messageIdHex] = edit
        if deleted || optimisticByTarget[record.messageIdHex]?.plaintext == record.plaintext {
            optimisticByTarget[record.messageIdHex] = nil
        }
    }

    func preparedEditCount(_ id: String) -> UInt64? {
        guard preparedIDs.contains(id) else { return nil }
        return preparedSummaries[id]?.editCount ?? 0
    }

    /// Mirrors an authoritative timeline row and returns every original message
    /// id whose displayed body may have changed.
    func setRecord(
        _ record: AppMessageRecordFfi,
        invalidated: Bool,
        deleted: Bool
    ) -> Set<String> {
        var affected = removeStoredEdit(messageIdHex: record.messageIdHex)
        guard case .edit(let targetMessageIdHex) = MessageSemantics.classify(record),
              !record.messageIdHex.isEmpty,
              !targetMessageIdHex.isEmpty
        else { return affected }

        editsById[record.messageIdHex] = StoredEdit(
            record: record,
            targetMessageIdHex: targetMessageIdHex,
            isUsable: !invalidated && !deleted
        )
        editIdsByTarget[targetMessageIdHex, default: []].insert(record.messageIdHex)
        affected.insert(targetMessageIdHex)

        // The overlay clears on ANY matching authoritative arrival. An
        // invalidated or deleted record is the authority saying the edit was
        // rejected — leaving the overlay in place keeps rendering the
        // rejected text indefinitely.
        if let optimistic = optimisticByTarget[targetMessageIdHex],
           optimistic.sender == record.sender,
           optimistic.plaintext == record.plaintext {
            optimisticByTarget[targetMessageIdHex] = nil
        }
        return affected
    }

    @discardableResult
    func removeRecord(messageIdHex: String) -> Set<String> {
        preparedIDs.remove(messageIdHex)
        preparedSummaries[messageIdHex] = nil
        return removeStoredEdit(messageIdHex: messageIdHex)
    }

    func displayRecord(for base: AppMessageRecordFfi) -> AppMessageRecordFfi {
        guard let replacement = replacement(for: base) else { return base }
        return AppMessageRecordFfi(
            messageIdHex: base.messageIdHex,
            direction: base.direction,
            groupIdHex: base.groupIdHex,
            sender: base.sender,
            plaintext: replacement.plaintext,
            contentTokens: replacement.contentTokens,
            kind: base.kind,
            tags: base.tags,
            sourceEpoch: base.sourceEpoch,
            retentionSeconds: base.retentionSeconds,
            retentionExpiresAt: base.retentionExpiresAt,
            recordedAt: base.recordedAt,
            receivedAt: base.receivedAt
        )
    }

    func isEdited(_ base: AppMessageRecordFfi) -> Bool {
        (preparedSummaries[base.messageIdHex]?.editCount ?? 0) > 0 || replacement(for: base) != nil
    }

    func setOptimistic(
        targetMessageIdHex: String,
        sender: String,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi
    ) {
        optimisticByTarget[targetMessageIdHex] = OptimisticEdit(
            sender: sender,
            plaintext: plaintext,
            contentTokens: contentTokens
        )
    }

    func removeOptimistic(targetMessageIdHex: String) {
        optimisticByTarget[targetMessageIdHex] = nil
    }

    func removeAllOptimistic() {
        optimisticByTarget.removeAll()
    }

    /// Durable, usable edit records for `base` in chronological order (ties
    /// broken by message id). Optimistic edits are excluded — they have no
    /// authoritative record or source timestamp yet.
    func editRecords(for base: AppMessageRecordFfi) -> [AppMessageRecordFfi] {
        guard let editIds = editIdsByTarget[base.messageIdHex] else { return [] }
        return editIds
            .compactMap { editsById[$0] }
            .filter { $0.isUsable && $0.record.sender == base.sender }
            .map(\.record)
            .sorted { lhs, rhs in
                if lhs.recordedAt != rhs.recordedAt {
                    return lhs.recordedAt < rhs.recordedAt
                }
                return lhs.messageIdHex < rhs.messageIdHex
            }
    }

    private func replacement(
        for base: AppMessageRecordFfi
    ) -> (plaintext: String, contentTokens: MarkdownDocumentFfi)? {
        if let optimistic = optimisticByTarget[base.messageIdHex],
           optimistic.sender == base.sender {
            return (optimistic.plaintext, optimistic.contentTokens)
        }

        guard !preparedIDs.contains(base.messageIdHex),
              let edit = editRecords(for: base).last else { return nil }
        return (edit.plaintext, edit.contentTokens)
    }

    private func removeStoredEdit(messageIdHex: String) -> Set<String> {
        guard let previous = editsById.removeValue(forKey: messageIdHex) else { return [] }
        editIdsByTarget[previous.targetMessageIdHex]?.remove(messageIdHex)
        if editIdsByTarget[previous.targetMessageIdHex]?.isEmpty == true {
            editIdsByTarget[previous.targetMessageIdHex] = nil
        }
        return [previous.targetMessageIdHex]
    }
}
