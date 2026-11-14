@testable import whitenoise_ios
import MarmotKit

/// Runs the production projection builds and counts them, so a test can tell
/// when a conversation cache rebuilt a row and when it reused one.
@MainActor
final class ProjectionBuildCounter {
    private(set) var markdownBuilds = 0
    private(set) var agentEventBuilds = 0
    /// Media builds from resolved outcomes and from attachment tags together.
    private(set) var mediaBuilds = 0
    private(set) var groupSystemBuilds = 0

    var builders: ConversationProjectionBuilders {
        ConversationProjectionBuilders(
            markdown: { [self] record, mentionDisplayName in
                markdownBuilds += 1
                return ConversationProjectionBuilders.live.markdown(record, mentionDisplayName)
            },
            agentEvent: { [self] record in
                agentEventBuilds += 1
                return ConversationProjectionBuilders.live.agentEvent(record)
            },
            mediaFromOutcomes: { [self] outcomes, ownerId, messageId, sourceMessageId in
                mediaBuilds += 1
                return ConversationProjectionBuilders.live.mediaFromOutcomes(outcomes, ownerId, messageId, sourceMessageId)
            },
            mediaFromReferences: { [self] references, ownerId in
                mediaBuilds += 1
                return ConversationProjectionBuilders.live.mediaFromReferences(references, ownerId)
            },
            groupSystemText: { [self] record, groupSystem, currentAccountIdHex, displayName in
                groupSystemBuilds += 1
                return ConversationProjectionBuilders.live.groupSystemText(record, groupSystem, currentAccountIdHex, displayName)
            }
        )
    }
}
