// swiftlint:disable no_test_hook_in_app_code
import Foundation
import MarmotKit

/// Per-row markdown display-block cache for the conversation timeline. Owns the
/// `rowId -> MessageMarkdownDisplayProjection` map and its incremental
/// maintenance (build on insert/update, drop on removal or when a row stops
/// being a markdown bubble, prune rows no longer in the timeline). The build
/// itself lives in `MessageMarkdownDisplayProjection.build`; the mention resolver
/// is passed per call so this owns no conversation state. First peel of the
/// TimelineStore split — the row-display projections come out ahead of the core
/// message mirror.
@MainActor
final class ConversationMarkdownProjectionCache {
    private var projectionsByRowId: [String: MessageMarkdownDisplayProjection] = [:]
    private var projectionKeysByRowId: [String: ProjectionKey] = [:]
    private var timestampGenerationsByRowId: [String: Int] = [:]
    /// `MarkdownTimestampRenderClock.generation` the cache renders under.
    private(set) var timestampGeneration = 0

#if DEBUG
    private(set) var buildCountForTesting = 0
#endif

    private struct ProjectionKey: Equatable {
        let messageIdHex: String
        let direction: String
        let sender: String
        let plaintext: String
        let kind: UInt64
        let recordedAt: UInt64
        let receivedAt: UInt64
        let contentTokens: MarkdownDocumentFfi
        let tokenBlockCount: Int
        let tokensTruncated: Bool
        let tagCount: Int

        init(record: AppMessageRecordFfi) {
            messageIdHex = record.messageIdHex
            direction = record.direction
            sender = record.sender
            plaintext = record.plaintext
            kind = record.kind
            recordedAt = record.recordedAt
            receivedAt = record.receivedAt
            contentTokens = record.contentTokens
            tokenBlockCount = record.contentTokens.blocks.count
            tokensTruncated = record.contentTokens.truncated
            tagCount = record.tags.count
        }
    }

    func blocks(for item: TimelineItem) -> [MarkdownDisplayBlock]? {
        projectionsByRowId[item.id]?.blocks
    }

    func relativeTimestampSeconds(forRowId rowId: String) -> [Int64] {
        projectionsByRowId[rowId]?.timestamps.relativeUnixSeconds ?? []
    }

    @discardableResult
    func update(for item: TimelineItem, force: Bool = false, resolver: @escaping MarkdownMentionResolver) -> Bool {
        guard case .message(let record, _) = item.kind else {
            return remove(rowId: item.id)
        }
        guard Self.usesMessageBubbleMarkdownProjection(for: record) else {
            return remove(rowId: item.id)
        }
        let key = ProjectionKey(record: record)
        if !force, projectionKeysByRowId[item.id] == key,
           !MarkdownTimestampCachePolicy.needsRebuild(
               containsTimestamps: projectionsByRowId[item.id]?.timestamps.containsTimestamps == true,
               builtGeneration: timestampGenerationsByRowId[item.id],
               currentGeneration: timestampGeneration
           ) {
            return false
        }
#if DEBUG
        buildCountForTesting += 1
#endif
        let next = MessageMarkdownDisplayProjection.build(
            for: record,
            mentionDisplayName: resolver
        )
        if next.blocks == nil, next.mentionedAccountIds.isEmpty {
            return remove(rowId: item.id)
        }
        let changed = projectionsByRowId[item.id] != next
        projectionsByRowId[item.id] = next
        projectionKeysByRowId[item.id] = key
        timestampGenerationsByRowId[item.id] = timestampGeneration
        return changed
    }

    @discardableResult
    func remove(rowId: String) -> Bool {
        let projectionRemoved = projectionsByRowId.removeValue(forKey: rowId) != nil
        projectionKeysByRowId.removeValue(forKey: rowId)
        timestampGenerationsByRowId.removeValue(forKey: rowId)
        return projectionRemoved
    }

    @discardableResult
    func rebuild(for items: [TimelineItem], onlyRowsWithMentions: Bool, resolver: @escaping MarkdownMentionResolver) -> Bool {
        var changed = false
        var activeMessageRowIds = Set<String>()
        for item in items {
            guard case .message = item.kind else { continue }
            activeMessageRowIds.insert(item.id)
            if onlyRowsWithMentions,
               projectionsByRowId[item.id]?.mentionedAccountIds.isEmpty != false {
                continue
            }
            changed = update(
                for: item,
                force: onlyRowsWithMentions,
                resolver: resolver
            ) || changed
        }
        if !onlyRowsWithMentions {
            for rowId in Array(projectionKeysByRowId.keys) where !activeMessageRowIds.contains(rowId) {
                changed = remove(rowId: rowId) || changed
            }
        }
        return changed
    }

    /// Adopts a new timestamp render generation and rebuilds only the rows
    /// that render a timestamp.
    @discardableResult
    func applyTimestampGeneration(
        _ generation: Int,
        to items: [TimelineItem],
        resolver: @escaping MarkdownMentionResolver
    ) -> Bool {
        guard generation != timestampGeneration else { return false }
        timestampGeneration = generation
        var changed = false
        for item in items where projectionsByRowId[item.id]?.timestamps.containsTimestamps == true {
            changed = update(for: item, resolver: resolver) || changed
        }
        return changed
    }

    /// Re-renders rows whose `relative` text depends on the current clock.
    @discardableResult
    func refreshRelativeTimestamps(
        rowIds: Set<String>,
        in items: [TimelineItem],
        resolver: @escaping MarkdownMentionResolver
    ) -> Bool {
        var changed = false
        for item in items where rowIds.contains(item.id)
            && projectionsByRowId[item.id]?.timestamps.containsRelative == true {
            changed = update(for: item, force: true, resolver: resolver) || changed
        }
        return changed
    }

    /// Group-system and agent-event rows render through their own presentations,
    /// not the markdown bubble path, so they carry no markdown projection.
    static func usesMessageBubbleMarkdownProjection(for record: AppMessageRecordFfi) -> Bool {
        if GroupSystemEventPresentation.isDisplayable(record) {
            return false
        }
        switch MessageSemantics.classify(record) {
        case .agentActivity, .agentOperation:
            return false
        default:
            return true
        }
    }
}
