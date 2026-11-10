import Foundation
import MarmotKit

/// The Marmot calls `ConversationViewModel` makes to decline an invitation. An
/// admin invitee steps down first: MDK refuses the decline until it has.
struct InviteDeclineCalls {
    var selfDemote: @MainActor (
        AppState, GroupChangeAdvisoryPrompter, _ accountRef: String, _ groupIdHex: String
    ) async throws -> GroupMutationResultFfi
    var decline: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String
    ) async throws -> GroupInviteDeclineResultFfi

    static let live = InviteDeclineCalls(
        selfDemote: { appState, prompter, accountRef, groupIdHex in
            try await GroupChangeAdvisoryRetry.perform(prompter: prompter, client: {
                try appState.currentMarmotClient()
            }, accountRef: accountRef, groupIdHex: groupIdHex) { client in
                try await client.selfDemoteAdminDetailed(accountRef: accountRef, groupIdHex: groupIdHex)
            }
        },
        decline: { appState, accountRef, groupIdHex in
            try await appState.currentMarmotClient().declineGroupInvite(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
        }
    )
}
