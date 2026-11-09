import Foundation
import MarmotKit

/// The builds behind the conversation timeline's per-row markdown and
/// agent-event projection caches. The caches decide when a row needs a build;
/// these produce it.
struct ConversationProjectionBuilders {
    var markdown: @MainActor (
        AppMessageRecordFfi, _ mentionDisplayName: @escaping MarkdownMentionResolver
    ) -> MessageMarkdownDisplayProjection
    /// The agent activity or operation display, or nil for any other message.
    var agentEvent: @MainActor (AppMessageRecordFfi) -> AgentEventPresentation.Display?

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
        }
    )
}
