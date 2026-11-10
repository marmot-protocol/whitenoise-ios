import Foundation
import MarmotKit

/// The builds behind the conversation timeline's per-row markdown, agent-event
/// and media projection caches. The caches decide when a row needs a build;
/// these produce it.
struct ConversationProjectionBuilders {
    var markdown: @MainActor (
        AppMessageRecordFfi, _ mentionDisplayName: @escaping MarkdownMentionResolver
    ) -> MessageMarkdownDisplayProjection
    /// The agent activity or operation display, or nil for any other message.
    var agentEvent: @MainActor (AppMessageRecordFfi) -> AgentEventPresentation.Display?
    /// Media display items from the outcomes Marmot resolved for a row.
    var mediaFromOutcomes: @MainActor (
        [MediaAttachmentOutcomeFfi], _ ownerId: String, _ messageId: String, _ sourceMessageId: String?
    ) -> [MessageMediaAttachment]
    /// Media display items from a row's own attachment tags, for rows with no
    /// resolved outcomes yet.
    var mediaFromReferences: @MainActor (
        [MediaAttachmentReferenceFfi], _ ownerId: String
    ) -> [MessageMediaAttachment]

    static let live = ConversationProjectionBuilders(
        markdown: { record, mentionDisplayName in
            MessageMarkdownDisplayProjection.build(for: record, mentionDisplayName: mentionDisplayName)
        },
        agentEvent: { record in
            switch MessageSemantics.classify(record) {
            case .agentActivity, .agentOperation:
                AgentEventPresentation.display(for: record)
            default:
                nil
            }
        },
        mediaFromOutcomes: { outcomes, ownerId, messageId, sourceMessageId in
            MessageMediaAttachment.displayItems(
                fromOutcomes: outcomes, ownerId: ownerId, messageId: messageId, sourceMessageId: sourceMessageId
            )
        },
        mediaFromReferences: { references, ownerId in
            MessageMediaAttachment.displayItems(from: references, ownerId: ownerId)
        }
    )
}
