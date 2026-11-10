@testable import whitenoise_ios
import Foundation
import MarmotKit
import Testing

/// Stands in for the Marmot calls a `ComposerModel` makes. Tests replace any call
/// at any point; a call the test didn't set records an issue.
@MainActor
final class ComposerMarmotDouble {
    var sendDraft: @MainActor (
        _ accountRef: String, _ revision: MessageDraftRevisionFfi, _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi = { _, _, clientToken in
        Issue.record("unexpected draft send")
        return LocalSendAcceptanceFfi(clientToken: clientToken, messageIdHex: "")
    }

    var reply: @MainActor (
        _ accountRef: String, _ groupIdHex: String, _ targetMessageId: String, _ text: String, _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi = { _, _, _, _, clientToken in
        Issue.record("unexpected reply send")
        return LocalSendAcceptanceFfi(clientToken: clientToken, messageIdHex: "")
    }

    var sendText: @MainActor (
        _ accountRef: String, _ groupIdHex: String, _ text: String, _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi = { _, _, _, clientToken in
        Issue.record("unexpected text send")
        return LocalSendAcceptanceFfi(clientToken: clientToken, messageIdHex: "")
    }

    var localSendStatus: @MainActor (
        _ accountRef: String, _ groupIdHex: String, _ clientToken: String
    ) async throws -> LocalSendStatusFfi? = { _, _, _ in
        Issue.record("unexpected local send status read")
        return nil
    }

    /// Composer calls that go to this double's current closures.
    var calls: ComposerMarmotCalls {
        ComposerMarmotCalls(
            sendDraft: { _, accountRef, revision, clientToken in
                try await self.sendDraft(accountRef, revision, clientToken)
            },
            reply: { _, accountRef, groupIdHex, targetMessageId, text, clientToken in
                try await self.reply(accountRef, groupIdHex, targetMessageId, text, clientToken)
            },
            sendText: { _, accountRef, groupIdHex, text, clientToken in
                try await self.sendText(accountRef, groupIdHex, text, clientToken)
            },
            localSendStatus: { _, accountRef, groupIdHex, clientToken in
                try await self.localSendStatus(accountRef, groupIdHex, clientToken)
            }
        )
    }
}
