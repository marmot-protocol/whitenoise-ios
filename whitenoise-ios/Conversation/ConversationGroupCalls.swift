import Foundation
import MarmotKit

/// The Marmot calls a conversation makes about its group: accepting an
/// invitation, and reading the group's current conversation snapshot.
struct ConversationGroupCalls {
    var acceptInvite: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String
    ) async throws -> AppGroupRecordFfi
    var conversationSnapshot: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String
    ) async throws -> GroupConversationSnapshotFfi

    static let live = ConversationGroupCalls(
        acceptInvite: { appState, accountRef, groupIdHex in
            try await appState.currentMarmotClient().acceptGroupInvite(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
        },
        conversationSnapshot: { appState, accountRef, groupIdHex in
            try await appState.currentMarmotClient().groupConversationSnapshot(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
        }
    )
}
