@testable import whitenoise_ios
import MarmotKit

/// Runs the production projection builds and counts them, so a test can tell
/// when a conversation cache rebuilt a row and when it reused one.
@MainActor
final class ProjectionBuildCounter {
    private(set) var markdownBuilds = 0
    private(set) var agentEventBuilds = 0

    var builders: ConversationProjectionBuilders {
        ConversationProjectionBuilders(
            markdown: { [self] record, mentionDisplayName in
                markdownBuilds += 1
                return ConversationProjectionBuilders.live.markdown(record, mentionDisplayName)
            },
            agentEvent: { [self] record in
                agentEventBuilds += 1
                return ConversationProjectionBuilders.live.agentEvent(record)
            }
        )
    }
}
