import Foundation
import MarmotKit

/// The Marmot calls `ComposerModel` makes to admit a text message and to read back
/// an uncertain admission. Each resolves the runtime client from `AppState` right
/// before its call, as the composer did.
struct ComposerMarmotCalls {
    var sendDraft: @MainActor (
        AppState, _ accountRef: String, _ revision: MessageDraftRevisionFfi, _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi
    var reply: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String, _ targetMessageId: String, _ text: String,
        _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi
    var sendText: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String, _ text: String, _ clientToken: String
    ) async throws -> LocalSendAcceptanceFfi
    var localSendStatus: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String, _ clientToken: String
    ) async throws -> LocalSendStatusFfi?

    static let live = ComposerMarmotCalls(
        sendDraft: { appState, accountRef, revision, clientToken in
            try await appState.currentMarmotClient().sendDraftWithClientToken(
                accountRef: accountRef,
                revision: revision,
                attachments: [],
                clientToken: clientToken
            )
        },
        reply: { appState, accountRef, groupIdHex, targetMessageId, text, clientToken in
            try await appState.currentMarmotClient().replyWithClientToken(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                targetMessageId: targetMessageId,
                text: text,
                clientToken: clientToken
            )
        },
        sendText: { appState, accountRef, groupIdHex, text, clientToken in
            try await appState.currentMarmotClient().sendTextWithClientToken(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                text: text,
                clientToken: clientToken
            )
        },
        localSendStatus: { appState, accountRef, groupIdHex, clientToken in
            try await appState.currentMarmotClient().localSendStatus(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                clientToken: clientToken
            )
        }
    )
}
