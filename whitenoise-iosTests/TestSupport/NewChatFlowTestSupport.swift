@testable import whitenoise_ios
import MarmotKit
import Testing

/// Stands in for Marmot behind a `NewChatFlowViewModel`. Tests replace either
/// operation at any point; an operation the test didn't set records an issue.
@MainActor
final class NewChatFlowMarmotDouble {
    /// The reusable direct chat's group id for `peerAccountId`, or nil when none exists.
    var existingDirectChat: @MainActor (_ accountRef: String, _ peerAccountId: String) async throws -> String? = { _, _ in
        Issue.record("unexpected existing direct chat lookup")
        return nil
    }

    /// The new group's id, or nil when MDK found no requested member available.
    var createGroup: @MainActor (
        _ accountRef: String,
        _ name: String,
        _ memberRefs: [String],
        _ options: CreateGroupOptionsFfi
    ) async throws -> String? = { _, _, _, _ in
        Issue.record("unexpected group creation")
        return "unexpected"
    }

    /// The per-account outcomes the create reports alongside its group.
    var memberOutcomes: [MemberResolutionOutcomeFfi] = []
}

/// A flow whose Marmot lookups and group creation go to `marmot`.
@MainActor
func newChatFlow(
    starter: DirectChatStarter? = nil,
    marmot: NewChatFlowMarmotDouble
) -> NewChatFlowViewModel {
    NewChatFlowViewModel(
        starter: starter,
        findExistingDirectChat: { _, accountRef, peerAccountId in
            try await marmot.existingDirectChat(accountRef, peerAccountId)
                .map { existingDirectConversation(groupIdHex: $0) }
        },
        createGroup: { _, accountRef, name, memberRefs, options in
            let groupIdHex = try await marmot.createGroup(accountRef, name, memberRefs, options)
            return DetailedGroupCreationResultFfi(
                created: groupIdHex.map {
                    CreatedGroupFfi(groupIdHex: $0, chatListRow: chatListRow(groupIdHex: $0, title: name))
                },
                memberOutcomes: marmot.memberOutcomes
            )
        }
    )
}
