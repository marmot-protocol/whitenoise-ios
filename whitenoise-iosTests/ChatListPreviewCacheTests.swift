import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct ChatListPreviewCacheTests {

    @Test func itemCachesSanitizedPreviewAndLowercaseSearchHaystackAtConstruction() {
        let bech32 = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let tokens = MarkdownDocumentFfi(blocks: [
            .paragraph(inlines: [
                .text(content: "Hello "),
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32)),
            ]),
        ], truncated: false)
        var resolverCalls = 0

        let item = ChatsListViewModel.Item(
            row: row(
                title: " Team\nRoom ",
                lastMessage: preview(plaintext: "fallback", contentTokens: tokens)
            ),
            avatarURL: nil,
            title: "Team Room",
            mentionDisplayName: { entity in
                resolverCalls += 1
                return entity.bech32 == bech32 ? "ALICE" : nil
            }
        )

        #expect(item.title == "Team Room")
        #expect(item.previewText == "Hello @ALICE")
        #expect(item.searchHaystack.contains("team room"))
        #expect(item.searchHaystack.contains("hello @alice"))

        _ = item.previewText
        _ = item.searchHaystack
        #expect(resolverCalls == 1)
    }

    @Test func chatRowSubtitleDecoratesCachedPreviewTextOnly() {
        let sentItem = ChatsListViewModel.Item(
            row: row(
                lastMessage: preview(sender: "self", plaintext: " hello\nthere ")
            ),
            avatarURL: nil,
            title: "Room"
        )
        #expect(ChatRow.subtitleText(for: sentItem, activeAccountIdHex: "self") == "You: hello there")

        let emptySentItem = ChatsListViewModel.Item(
            row: row(
                lastMessage: preview(sender: "self", plaintext: "   ")
            ),
            avatarURL: nil,
            title: "Room"
        )
        #expect(ChatRow.subtitleText(for: emptySentItem, activeAccountIdHex: "self") == "You sent a message")

        let emptyItem = ChatsListViewModel.Item(row: row(lastMessage: nil), avatarURL: nil, title: "Room")
        #expect(ChatRow.subtitleText(for: emptyItem, activeAccountIdHex: "self") == "No messages yet")
    }

    private func row(
        groupIdHex: String = "0123456789abcdef",
        title: String = "Room",
        lastMessage: ChatListMessagePreviewFfi? = nil
    ) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: groupIdHex,
            archived: false,
            pendingConfirmation: false,
            title: title,
            groupName: title,
            avatarUrl: nil,
            avatar: nil,
            lastMessage: lastMessage,
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1
        )
    }

    private func preview(
        messageIdHex: String = "01",
        sender: String = "sender",
        plaintext: String = "hello",
        contentTokens: MarkdownDocumentFfi = MarkdownDocumentFfi(blocks: [], truncated: false),
        kind: UInt64 = MessageSemantics.kindChat,
        timelineAt: UInt64 = 1,
        deleted: Bool = false
    ) -> ChatListMessagePreviewFfi {
        ChatListMessagePreviewFfi(
            messageIdHex: messageIdHex,
            sender: sender,
            senderDisplayName: nil,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            timelineAt: timelineAt,
            deleted: deleted
        )
    }
}
