import Foundation
import MarmotKit

/// Per-row media display cache for the conversation timeline. Owns three dumb
/// mirrors and their incremental maintenance:
///
/// - `referencesByMessageId` — resolved, downloadable media references mirrored
///   from each timeline row's `media` projection at ingest (Marmot resolves the
///   imeta tags + source_epoch). No iOS-side derivation, no separate `listMedia`
///   round-trip.
/// - `pendingByRowId` — optimistic attachments staged by the send pipeline,
///   keyed by the pending/transient row id. Takes precedence over the projection
///   so a just-sent bubble renders before its confirmed row arrives.
/// - `projectionsByRowId` — the built `MessageMediaAttachment` display items per
///   row, derived from the references (or a tag-classification fallback for
///   records with no captured row projection).
///
/// Sibling to `ConversationMarkdownProjectionCache` — both peel the row-display
/// projections out of the view model ahead of the core message mirror. This one
/// is bigger because it carries the two extra write-paths (ingest references and
/// send-pipeline pending media). It owns no conversation state: the
/// message-id → row resolution needed by the by-message-id update path is passed
/// in per call.
@MainActor
final class ConversationMediaProjectionCache {
    private var referencesByMessageId: [String: [MediaAttachmentReferenceFfi]] = [:]
    private var pendingByRowId: [String: [MessageMediaAttachment]] = [:]
    private var projectionsByRowId: [String: [MessageMediaAttachment]] = [:]
#if DEBUG
    // Counts build invocations across both record-backed and classify-backed
    // media paths so tests can catch accidental body-time rebuilds.
    private(set) var buildCountForTesting = 0
#endif

    // MARK: Reads

    func items(for item: TimelineItem) -> [MessageMediaAttachment] {
        if let pending = pendingByRowId[item.id] {
            return pending
        }
        return projectionsByRowId[item.id] ?? []
    }

    func build(for record: AppMessageRecordFfi, ownerId: String) -> [MessageMediaAttachment] {
        // Prefer the row-resolved references (correct source_epoch, drop-bad).
        // Fall back to tag classification only for records with no captured row
        // projection (e.g. local/optimistic sends before the confirmed row).
        let references: [MediaAttachmentReferenceFfi]
        if let rowReferences = referencesByMessageId[record.messageIdHex], !rowReferences.isEmpty {
            references = rowReferences
        } else if case .media(let classified) = MessageSemantics.classify(record) {
            references = classified
        } else {
            return []
        }
#if DEBUG
        buildCountForTesting += 1
#endif
        return MessageMediaAttachment.displayItems(from: references, ownerId: ownerId)
    }

    // MARK: Resolved references (ingest write-path)

    func setReferences(_ references: [MediaAttachmentReferenceFfi], forMessageId messageIdHex: String) {
        referencesByMessageId[messageIdHex] = references
    }

    func removeReferences(forMessageId messageIdHex: String) {
        referencesByMessageId[messageIdHex] = nil
    }

    /// Mirrors the resolved references for one message (from the timeline row, or
    /// from an upload result so a just-sent bubble renders before its row
    /// arrives) and refreshes that message's projection.
    @discardableResult
    func replaceReferences(
        _ references: [MediaAttachmentReferenceFfi],
        forMessageId messageIdHex: String,
        itemResolver: (String) -> TimelineItem?
    ) -> Bool {
        guard referencesByMessageId[messageIdHex] != references else { return false }
        referencesByMessageId[messageIdHex] = references
        return updateProjection(forMessageId: messageIdHex, itemResolver: itemResolver)
    }

    // MARK: Pending optimistic media (send-pipeline write-path)

    var hasPending: Bool { !pendingByRowId.isEmpty }

    func pending(forRowId rowId: String) -> [MessageMediaAttachment]? {
        pendingByRowId[rowId]
    }

    func setPending(_ items: [MessageMediaAttachment], forRowId rowId: String) {
        pendingByRowId[rowId] = items
    }

    @discardableResult
    func removePending(forRowId rowId: String) -> [MessageMediaAttachment]? {
        pendingByRowId.removeValue(forKey: rowId)
    }

    func removeAllPending() {
        pendingByRowId.removeAll()
    }

    // MARK: Projection maintenance

    @discardableResult
    func update(for item: TimelineItem) -> Bool {
        if pendingByRowId[item.id] != nil {
            return remove(rowId: item.id)
        }
        guard case .message(let record, _) = item.kind else {
            return remove(rowId: item.id)
        }
        let next = build(for: record, ownerId: item.id)
        guard !next.isEmpty else {
            return remove(rowId: item.id)
        }
        guard projectionsByRowId[item.id] != next else { return false }
        projectionsByRowId[item.id] = next
        return true
    }

    @discardableResult
    func remove(rowId: String) -> Bool {
        projectionsByRowId.removeValue(forKey: rowId) != nil
    }

    @discardableResult
    func rebuild(for items: [TimelineItem]) -> Bool {
        var changed = false
        var activeRowIds = Set<String>()
        for item in items {
            guard case .message = item.kind else { continue }
            activeRowIds.insert(item.id)
            changed = update(for: item) || changed
        }
        for rowId in Array(projectionsByRowId.keys) where !activeRowIds.contains(rowId) {
            projectionsByRowId[rowId] = nil
            changed = true
        }
        return changed
    }

    @discardableResult
    func updateProjection(forMessageId messageIdHex: String, itemResolver: (String) -> TimelineItem?) -> Bool {
        let rowId = "msg:\(messageIdHex)"
        guard let item = itemResolver(messageIdHex) else {
            return remove(rowId: rowId)
        }
        return update(for: item)
    }

#if DEBUG
    var referenceCountForTesting: Int {
        referencesByMessageId.values.reduce(0) { $0 + $1.count }
    }
#endif
}
