@testable import whitenoise_ios
import MarmotKit
import Testing

/// A starter that runs `startDirect` instead of MDK's canonical direct-chat
/// start and `create` instead of a separate group creation. Each returns the
/// group id it gives, with a direct chat-list row for that group unless
/// `startDirectRow` is false. An operation the test didn't set records an issue.
@MainActor
func directChatStarter(
    startDirect: @escaping @MainActor (_ accountRef: String, _ memberRef: String) async throws -> String = { _, _ in
        Issue.record("unexpected canonical direct-chat start")
        return "unexpected"
    },
    startDirectRow: Bool = true,
    create: @escaping @MainActor (_ accountRef: String, _ memberRef: String) async throws -> String = { _, _ in
        Issue.record("unexpected separate chat creation")
        return "unexpected"
    }
) -> DirectChatStarter {
    DirectChatStarter(
        startDirect: { _, accountRef, memberRef in
            let groupIdHex = try await startDirect(accountRef, memberRef)
            return DirectChatStarter.StartedDirectChat(
                groupIdHex: groupIdHex,
                chatListRow: startDirectRow
                    ? chatListRow(groupIdHex: groupIdHex, title: groupIdHex, conversationKind: .direct)
                    : nil
            )
        },
        createGroup: { _, accountRef, memberRef in
            let groupIdHex = try await create(accountRef, memberRef)
            return CreatedGroupFfi(
                groupIdHex: groupIdHex,
                chatListRow: chatListRow(groupIdHex: groupIdHex, title: groupIdHex, conversationKind: .direct)
            )
        }
    )
}
