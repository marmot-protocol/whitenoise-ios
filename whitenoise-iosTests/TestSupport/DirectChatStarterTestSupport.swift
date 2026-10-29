@testable import whitenoise_ios
import MarmotKit

/// A starter whose group creation runs `create` instead of Marmot and returns
/// the group id it gives, with a direct chat-list row for that group.
@MainActor
func directChatStarter(
    create: @escaping @MainActor (_ accountRef: String, _ memberRef: String) async throws -> String
) -> DirectChatStarter {
    DirectChatStarter { _, accountRef, memberRef in
        let groupIdHex = try await create(accountRef, memberRef)
        return CreatedGroupFfi(
            groupIdHex: groupIdHex,
            chatListRow: chatListRow(groupIdHex: groupIdHex, title: groupIdHex, conversationKind: .direct)
        )
    }
}
