import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

func chatListPreview(
    messageIdHex: String,
    sender: String = hex("11"),
    senderDisplayName: String? = nil,
    plaintext: String = "hello",
    contentTokens: MarkdownDocumentFfi = .emptyDocument,
    kind: UInt64 = MessageSemantics.kindChat,
    timelineAt: UInt64 = 1,
    deleted: Bool = false
) -> ChatListMessagePreviewFfi {
    ChatListMessagePreviewFfi(
        groupSystem: nil,
        messageIdHex: messageIdHex,
        sender: sender,
        senderDisplayName: senderDisplayName,
        plaintext: plaintext,
        contentTokens: contentTokens,
        kind: kind,
        timelineAt: timelineAt,
        deleted: deleted
    )
}

func presentedChatSnapshot(_ rows: [ChatListRowFfi]) -> PresentedChatListSnapshotFfi {
    PresentedChatListSnapshotFfi(
        rows: rows.map { row in
            PresentedChatRowFfi(
                row: row,
                presentation: ConversationPresentationFfi(
                    title: .literal(text: row.title),
                    avatar: .placeholder(stableSeed: row.groupIdHex, source: .groupFallback),
                    titleSource: .group, avatarSource: .groupFallback, peerId: nil, resolution: .lastKnown
                ),
                avatarAsset: nil
            )
        },
        presentationVersion: PresentationVersionFfi(accountStoreEpoch: Data([1]), revision: 1)
    )
}

func chatListRow(
    groupIdHex: String,
    pinned: Bool = false,
    pinnedPosition: UInt32? = nil,
    archived: Bool = false,
    pendingConfirmation: Bool = false,
    title: String,
    groupName: String? = nil,
    avatar: ChatListAvatarFfi? = nil,
    avatarUrl: String? = nil,
    lastMessage: ChatListMessagePreviewFfi? = nil,
    unreadCount: UInt64 = 0,
    manuallyMarkedUnread: Bool = false,
    unreadMentionCount: UInt64 = 0,
    unreadMention: Bool = false,
    firstUnreadMessageIdHex: String? = nil,
    lastReadMessageIdHex: String? = nil,
    lastReadTimelineAt: UInt64? = nil,
    conversationCreatedAt: UInt64? = nil,
    activitySortAt: UInt64? = nil,
    updatedAt: UInt64 = 1,
    selfMembership: SelfMembershipFfi = .member,
    conversationKind: ChatConversationKindFfi = .group,
    muted: Bool = false,
    mutedUntilMs: Int64? = nil,
    leaveRequestPending: Bool = false
) -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: groupIdHex,
        pinned: pinned,
        pinnedPosition: pinnedPosition,
        archived: archived,
        pendingConfirmation: pendingConfirmation,
        title: title,
        groupName: groupName ?? title,
        avatarUrl: avatarUrl,
        avatar: avatar,
        lastMessage: lastMessage,
        unreadCount: unreadCount,
        hasUnread: unreadCount > 0 || manuallyMarkedUnread,
        manuallyMarkedUnread: manuallyMarkedUnread,
        unreadMentionCount: unreadMentionCount,
        unreadMention: unreadMention,
        firstUnreadMessageIdHex: firstUnreadMessageIdHex,
        lastReadMessageIdHex: lastReadMessageIdHex,
        lastReadTimelineAt: lastReadTimelineAt,
        conversationCreatedAt: conversationCreatedAt ?? updatedAt,
        activitySortAt: activitySortAt ?? updatedAt,
        updatedAt: updatedAt,
        selfMembership: selfMembership,
        conversationKind: conversationKind,
        muted: muted,
        mutedUntilMs: mutedUntilMs,
        leaveRequestPending: leaveRequestPending,
        leaveRequestedAtMs: leaveRequestPending ? updatedAt * 1_000 : nil
    )
}

// Existing projection fixtures use the same message and invite selection as MDK.
extension PresentedChatRowFfi {
    init(row: ChatListRowFfi, presentation: ConversationPresentationFfi, avatarAsset: AvatarAssetFfi?) {
        self.init(
            draftVersion: nil,
            preview: row.lastMessage != nil ? .message : (row.pendingConfirmation ? .invitation : .empty),
            actions: Self.testActions(), row: row, presentation: presentation, avatarAsset: avatarAsset
        )
    }

    static func testActions(
        read: Bool = false, unread: Bool = false, pin: Bool = false, unpin: Bool = false,
        mute: Bool = false, unmute: Bool = false, archive: Bool = false, restore: Bool = false,
        leave: Bool = false, delete: Bool = false
    ) -> ChatListRowActionsFfi {
        ChatListRowActionsFfi(
            canMarkRead: read, canMarkUnread: unread, canPin: pin, canUnpin: unpin,
            canMute: mute, canUnmute: unmute, canArchive: archive, canRestore: restore,
            canStartLeave: leave, canDeleteLocal: delete
        )
    }
}
