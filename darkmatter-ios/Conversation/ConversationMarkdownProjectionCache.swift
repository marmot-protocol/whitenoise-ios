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

    func blocks(for item: TimelineItem) -> [MarkdownDisplayBlock]? {
        projectionsByRowId[item.id]?.blocks
    }

    @discardableResult
    func update(for item: TimelineItem, resolver: @escaping MarkdownMentionResolver) -> Bool {
        guard case .message(let record, _) = item.kind else {
            return remove(rowId: item.id)
        }
        guard Self.usesMessageBubbleMarkdownProjection(for: record) else {
            return remove(rowId: item.id)
        }
        let next = MessageMarkdownDisplayProjection.build(
            for: record,
            mentionDisplayName: resolver
        )
        if next.blocks == nil, next.mentionedAccountIds.isEmpty {
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
            changed = update(for: item, resolver: resolver) || changed
        }
        if !onlyRowsWithMentions {
            for rowId in Array(projectionsByRowId.keys) where !activeMessageRowIds.contains(rowId) {
                projectionsByRowId[rowId] = nil
                changed = true
            }
        }
        return changed
    }

    /// Group-system and agent-event rows render through their own presentations,
    /// not the markdown bubble path, so they carry no markdown projection.
    static func usesMessageBubbleMarkdownProjection(for record: AppMessageRecordFfi) -> Bool {
        if GroupSystemEventPresentation.isDisplayable(record) {
            return false
        }
        if AgentEventPresentation.display(for: record) != nil {
            return false
        }
        return true
    }
}
