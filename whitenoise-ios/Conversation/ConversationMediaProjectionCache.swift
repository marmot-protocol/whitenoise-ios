import Foundation
import MarmotKit

/// Per-row media display cache for the conversation timeline. Owns three dumb
/// mirrors and their incremental maintenance:
///
/// - `referencesByMessageId` — accepted and rejected attachment outcomes mirrored
///   from each timeline row's `media` projection at ingest (Marmot resolves the
///   imeta tags + source_epoch). No iOS-side derivation, no separate `listMedia`
///   round-trip.
/// - `pendingByRowId` — optimistic attachments staged by the send pipeline,
///   keyed by the pending/transient row id. Takes precedence over the projection
///   so a just-sent bubble renders before its confirmed row arrives.
/// - `projectionsByRowId` — the built `MessageMediaAttachment` display items per
///   row, derived from the references. If a row mirror is present but empty, that
///   empty projection is authoritative; the tag-classification fallback is only
///   for local rows that have no captured Rust projection yet (optimistic upload /
///   compatibility records).
///
/// Sibling to `ConversationMarkdownProjectionCache` — both peel the row-display
/// projections out of the view model ahead of the core message mirror. This one
/// is bigger because it carries the two extra write-paths (ingest references and
/// send-pipeline pending media). It owns no conversation state: the
/// message-id → row resolution needed by the by-message-id update path is passed
/// in per call.
@MainActor
final class ConversationMediaProjectionCache {
    private var sourceIDs: [String: String] = [:]
    private var referencesByMessageId: [String: [MediaAttachmentOutcomeFfi]] = [:]
    private var pendingByRowId: [String: [MessageMediaAttachment]] = [:]
    private var projectionsByRowId: [String: [MessageMediaAttachment]] = [:]
    private var projectionKeysByRowId: [String: ProjectionKey] = [:]
#if DEBUG
    // Counts build invocations across both record-backed and classify-backed
    // media paths so tests can catch accidental body-time rebuilds.
    private(set) var buildCountForTesting = 0
#endif

    private enum ProjectionSourceKey: Equatable {
        case mirrored([MediaAttachmentOutcomeFfi])
        case fallback(kind: UInt64, tags: [MessageTagFfi])
    }

    private struct ProjectionKey: Equatable {
        let ownerId: String
        let messageIdHex: String
        let source: ProjectionSourceKey
        let sourceMessageID: String?

        init(
            record: AppMessageRecordFfi,
            ownerId: String,
            mirroredReferences: [MediaAttachmentOutcomeFfi]?,
            sourceMessageID: String?
        ) {
            self.sourceMessageID = sourceMessageID
            self.ownerId = ownerId
            messageIdHex = record.messageIdHex
            if let mirroredReferences {
                source = .mirrored(mirroredReferences)
            } else {
                source = .fallback(kind: record.kind, tags: record.tags)
            }
        }
    }

    // MARK: Reads

    func sourceMessageID(for messageID: String) -> String? { sourceIDs[messageID] }

    func items(for item: TimelineItem) -> [MessageMediaAttachment] {
        if let pending = pendingByRowId[item.id] {
            return pending
        }
        return projectionsByRowId[item.id] ?? []
    }

    func build(for record: AppMessageRecordFfi, ownerId: String) -> [MessageMediaAttachment] {
        // Prefer the row-resolved outcomes, including rejected siblings.
        // A present-but-empty mirror is authoritative: Rust saw the row and chose
        // no media, so do not re-derive media from tags here. Fall back to tag
        // classification only when there is no captured row projection at all
        // (e.g. local/optimistic sends before the confirmed row is mirrored).
        if let outcomes = referencesByMessageId[record.messageIdHex] {
            guard !outcomes.isEmpty else { return [] }
#if DEBUG
            buildCountForTesting += 1
#endif
            return MessageMediaAttachment.displayItems(fromOutcomes: outcomes, ownerId: ownerId,
                messageId: record.messageIdHex, sourceMessageId: sourceIDs[record.messageIdHex])
        }
        guard case .media(let references) = MessageSemantics.classify(record) else { return [] }
#if DEBUG
        buildCountForTesting += 1
#endif
        return MessageMediaAttachment.displayItems(from: references, ownerId: ownerId)
    }

    // MARK: Resolved references (ingest write-path)

    func setReferences(_ references: [MediaAttachmentReferenceFfi], forMessageId messageIdHex: String) {
        setOutcomes(Self.accepted(references), forMessageId: messageIdHex)
    }

    func setOutcomes(_ outcomes: [MediaAttachmentOutcomeFfi], forMessageId messageIdHex: String, sourceMessageId: String? = nil) {
        sourceIDs[messageIdHex] = sourceMessageId
        referencesByMessageId[messageIdHex] = outcomes
    }

    private static func accepted(_ references: [MediaAttachmentReferenceFfi]) -> [MediaAttachmentOutcomeFfi] {
        references.enumerated().map { .accepted(attachmentIndex: UInt32(clamping: $0.offset), reference: $0.element) }
    }

    func removeReferences(forMessageId messageIdHex: String) {
        referencesByMessageId[messageIdHex] = nil
        sourceIDs[messageIdHex] = nil
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
        let outcomes = Self.accepted(references)
        guard referencesByMessageId[messageIdHex] != outcomes else { return false }
        referencesByMessageId[messageIdHex] = outcomes
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
        let key = ProjectionKey(
            record: record,
            ownerId: item.id,
            mirroredReferences: referencesByMessageId[record.messageIdHex],
            sourceMessageID: sourceIDs[record.messageIdHex]
        )
        guard projectionKeysByRowId[item.id] != key else { return false }
        let next = build(for: record, ownerId: item.id)
        projectionKeysByRowId[item.id] = key
        guard !next.isEmpty else {
            return projectionsByRowId.removeValue(forKey: item.id) != nil
        }
        guard projectionsByRowId[item.id] != next else { return false }
        projectionsByRowId[item.id] = next
        return true
    }

    @discardableResult
    func remove(rowId: String) -> Bool {
        let removedProjection = projectionsByRowId.removeValue(forKey: rowId) != nil
        projectionKeysByRowId.removeValue(forKey: rowId)
        return removedProjection
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
        for rowId in Array(projectionKeysByRowId.keys) where !activeRowIds.contains(rowId) {
            changed = remove(rowId: rowId) || changed
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
