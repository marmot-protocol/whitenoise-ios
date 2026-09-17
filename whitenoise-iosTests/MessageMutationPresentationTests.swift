import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageMutationPolicyTests {
    @Test func forwardingPreservesExactPlaintextAndRejectsControlEvents() {
        let message = appRecord(plaintext: "  exact text\n", kind: MessageSemantics.kindChat)
        #expect(MessageForwardingPolicy.forwardableText(for: message) == "  exact text\n")

        let reaction = appRecord(
            plaintext: "👍",
            kind: MessageSemantics.kindReaction,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, hex("22")])]
        )
        #expect(MessageForwardingPolicy.forwardableText(for: reaction) == nil)
        #expect(MessageForwardingPolicy.forwardableText(for: appRecord(plaintext: "   ")) == nil)
    }

    @Test func editingIsLimitedToOwnDurableUserMessages() {
        let own = appRecord(direction: "sent")
        #expect(MessageEditingPolicy.canEdit(own, isDeleted: false, canSendMessages: true))
        #expect(!MessageEditingPolicy.canEdit(own, isDeleted: true, canSendMessages: true))
        #expect(!MessageEditingPolicy.canEdit(own, isDeleted: false, canSendMessages: false))
        #expect(!MessageEditingPolicy.canEdit(appRecord(direction: "received"), isDeleted: false, canSendMessages: true))

        let editEvent = appRecord(
            direction: "sent",
            kind: MessageSemantics.kindEdit,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, hex("22")])]
        )
        #expect(!MessageEditingPolicy.canEdit(editEvent, isDeleted: false, canSendMessages: true))
        #expect(MessageEditingPolicy.normalizedContent("  replacement  ") == "replacement")
        #expect(MessageEditingPolicy.normalizedContent(" \n ") == nil)
    }

    @Test func forwardingDestinationsIncludeAllExistingChatsExceptCurrentAndPending() {
        let current = hex("01")
        let alpha = hex("02")
        let beta = hex("03")
        let rows = [
            chatRow(id: beta, title: "beta"),
            chatRow(id: current, title: "Current"),
            chatRow(id: alpha, title: "Alpha"),
            chatRow(id: alpha, title: "Duplicate"),
            chatRow(id: hex("04"), title: "Archived", archived: true),
            chatRow(id: hex("05"), title: "Pending", pending: true),
            chatRow(id: hex("06"), title: "Left", membership: .left),
            chatRow(id: hex("07"), title: "Removed", membership: .removed),
        ]

        let destinations = MessageForwardDestinationPresentation.destinations(
            from: rows,
            excludingGroupIdHex: current
        )
        // Archived chats remain valid destinations (still a member); left and
        // removed chats are excluded — a forward to one fails at send.
        #expect(destinations.map(\.id) == [alpha, hex("04"), beta])
        #expect(destinations.map(\.title) == ["Alpha", "Archived", "beta"])
    }

    @MainActor
    @Test func forwardingDestinationsExcludeLeftAndRemovedChats() {
        // Left/removed rows persist in the chat-list model but a forward to
        // one fails at send; they must never be offered.
        let items = [
            chatItem(id: hex("01"), rowTitle: "Member", displayTitle: "Member"),
            chatItem(id: hex("02"), rowTitle: "Left", displayTitle: "Left", membership: .left),
            chatItem(id: hex("03"), rowTitle: "Removed", displayTitle: "Removed", membership: .removed),
        ]
        let fromItems = MessageForwardDestinationPresentation.destinations(
            from: items,
            excludingGroupIdHex: "other"
        )
        #expect(fromItems.map(\.id) == [hex("01")])

        let rows = [
            chatRow(id: hex("01"), title: "Member"),
            chatRow(id: hex("02"), title: "Left", membership: .left),
            chatRow(id: hex("03"), title: "Removed", membership: .removed),
        ]
        let fromRows = MessageForwardDestinationPresentation.destinations(
            from: rows,
            excludingGroupIdHex: "other"
        )
        #expect(fromRows.map(\.id) == [hex("01")])
    }

    @MainActor
    @Test func forwardingDestinationsUseEveryLiveEnrichedChatListItem() {
        let current = hex("11")
        let direct = hex("12")
        let group = hex("13")
        let items = [
            chatItem(id: current, rowTitle: "Current", displayTitle: "Current"),
            chatItem(id: direct, rowTitle: direct, displayTitle: "Alice"),
            chatItem(
                id: group,
                rowTitle: "Raw group",
                displayTitle: "Weekend plans",
                archived: true
            ),
        ]

        let destinations = MessageForwardDestinationPresentation.destinations(
            from: items,
            excludingGroupIdHex: current
        )

        #expect(destinations.map(\.id) == [direct, group])
        #expect(destinations.map(\.title) == ["Alice", "Weekend plans"])
    }

    @Test func forwardPickerFiltersTitlesWithoutChangingDestinationOrder() {
        let destinations = [
            MessageForwardDestination(id: "1", title: "Weekend Plans", avatarURL: nil),
            MessageForwardDestination(id: "2", title: "Alice", avatarURL: nil),
            MessageForwardDestination(id: "3", title: "Work Updates", avatarURL: nil),
        ]

        #expect(ForwardMessagePresentation.filtered(destinations, query: "").map(\.id) == ["1", "2", "3"])
        #expect(ForwardMessagePresentation.filtered(destinations, query: "  work ").map(\.id) == ["3"])
        #expect(ForwardMessagePresentation.filtered(destinations, query: "PLANS").map(\.id) == ["1"])
        #expect(ForwardMessagePresentation.maximumDestinationCount == 5)
    }

    private func appRecord(
        messageIdHex: String = hex("11"),
        direction: String = "received",
        plaintext: String = "hello",
        kind: UInt64 = MessageSemantics.kindChat,
        tags: [MessageTagFfi] = []
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: messageIdHex,
            direction: direction,
            groupIdHex: hex("aa"),
            sender: hex("bb"),
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            recordedAt: 1,
            receivedAt: 1
        )
    }

    private func chatRow(
        id: String,
        title: String,
        archived: Bool = false,
        pending: Bool = false,
        membership: SelfMembershipFfi = .member
    ) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: id,
            pinned: false,
            pinnedPosition: nil,
            archived: archived,
            pendingConfirmation: pending,
            title: title,
            groupName: title,
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
            unreadCount: 0,
            hasUnread: false,
            manuallyMarkedUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            conversationCreatedAt: 1,
            activitySortAt: 1,
            updatedAt: 1,
            selfMembership: membership,
            conversationKind: .group,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: false,
            leaveRequestedAtMs: nil
        )
    }

    private func chatItem(
        id: String,
        rowTitle: String,
        displayTitle: String,
        archived: Bool = false,
        membership: SelfMembershipFfi = .member
    ) -> ChatsListViewModel.Item {
        ChatsListViewModel.Item(
            row: chatRow(
                id: id,
                title: rowTitle,
                archived: archived,
                membership: membership
            ),
            avatarURL: nil,
            title: displayTitle
        )
    }
}

@MainActor
struct ConversationEditProjectionTests {
    @Test func rejectedAuthoritativeEditClearsTheOptimisticOverlay() {
        let cache = ConversationEditProjectionCache()
        let target = appRecord(id: hex("10"), sender: hex("aa"), plaintext: "original", at: 1)
        cache.setOptimistic(
            targetMessageIdHex: target.messageIdHex,
            sender: target.sender,
            plaintext: "rejected edit",
            contentTokens: MarkdownDocumentFfi.emptyDocument
        )

        // The authoritative record for the same edit arrives invalidated:
        // the authority has rejected it, so the overlay must clear instead
        // of rendering the rejected text indefinitely.
        let rejected = editRecord(
            id: hex("20"), target: target.messageIdHex, sender: target.sender, text: "rejected edit", at: 2
        )
        _ = cache.setRecord(rejected, invalidated: true, deleted: false)

        #expect(cache.displayRecord(for: target).plaintext == "original")
    }


    @Test func latestValidEditFromOriginalAuthorWinsAndOptimisticEditCanRollBack() {
        let cache = ConversationEditProjectionCache()
        let target = appRecord(id: hex("10"), sender: hex("aa"), plaintext: "original", at: 1)
        let valid = editRecord(id: hex("20"), target: target.messageIdHex, sender: target.sender, text: "valid", at: 2)
        let wrongAuthor = editRecord(id: hex("30"), target: target.messageIdHex, sender: hex("bb"), text: "wrong", at: 3)
        let invalidated = editRecord(id: hex("40"), target: target.messageIdHex, sender: target.sender, text: "invalid", at: 4)

        _ = cache.setRecord(valid, invalidated: false, deleted: false)
        _ = cache.setRecord(wrongAuthor, invalidated: false, deleted: false)
        _ = cache.setRecord(invalidated, invalidated: true, deleted: false)
        #expect(cache.displayRecord(for: target).plaintext == "valid")
        #expect(cache.isEdited(target))

        cache.setOptimistic(
            targetMessageIdHex: target.messageIdHex,
            sender: target.sender,
            plaintext: "optimistic",
            contentTokens: .emptyDocument
        )
        #expect(cache.displayRecord(for: target).plaintext == "optimistic")
        cache.removeOptimistic(targetMessageIdHex: target.messageIdHex)
        #expect(cache.displayRecord(for: target).plaintext == "valid")

        _ = cache.setRecord(valid, invalidated: false, deleted: true)
        #expect(cache.displayRecord(for: target).plaintext == "original")
        #expect(!cache.isEdited(target))
    }

    @Test func timelineRendersOneOriginalRowWithLatestEditBodyAndEditedState() throws {
        let groupId = hex("cc")
        let sender = hex("dd")
        let targetId = hex("10")
        let store = TimelineStore(appState: nil, groupIdHex: groupId)
        let target = timelineRecord(
            id: targetId,
            groupId: groupId,
            sender: sender,
            text: "original",
            kind: MessageSemantics.kindChat,
            at: 1
        )
        let edit = timelineRecord(
            id: hex("20"),
            groupId: groupId,
            sender: sender,
            text: "replacement",
            kind: MessageSemantics.kindEdit,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, targetId])],
            at: 2
        )

        store.applyTimelinePage(
            TimelinePageFfi(messages: [target, edit], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(store.timeline.count == 1)
        let item = try #require(store.timeline.first)
        guard case .message(let rendered, _) = item.kind else {
            Issue.record("Expected an edited message row")
            return
        }
        #expect(rendered.messageIdHex == targetId)
        #expect(rendered.plaintext == "replacement")
        #expect(store.isEdited(targetId))
    }

    @Test func liveEditUpsertRefreshesOriginalRowAndRemovalRestoresIt() throws {
        let groupId = hex("cc")
        let sender = hex("dd")
        let targetId = hex("10")
        let editId = hex("20")
        let store = TimelineStore(appState: nil, groupIdHex: groupId)
        let target = timelineRecord(
            id: targetId,
            groupId: groupId,
            sender: sender,
            text: "original",
            kind: MessageSemantics.kindChat,
            at: 1
        )
        let edit = timelineRecord(
            id: editId,
            groupId: groupId,
            sender: sender,
            text: "replacement",
            kind: MessageSemantics.kindEdit,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, targetId])],
            at: 2
        )

        _ = store.applyTimelineRecord(target, updateTimeline: true)
        _ = store.applyTimelineRecord(edit, updateTimeline: true)
        let editedItem = try #require(store.timeline.first)
        guard case .message(let editedRecord, _) = editedItem.kind else {
            Issue.record("Expected an edited message row")
            return
        }
        #expect(store.timeline.count == 1)
        #expect(editedRecord.plaintext == "replacement")

        _ = store.removeTimelineRecord(messageIdHex: editId, updateTimeline: true)
        let restoredItem = try #require(store.timeline.first)
        guard case .message(let restoredRecord, _) = restoredItem.kind else {
            Issue.record("Expected the original message row")
            return
        }
        #expect(restoredRecord.plaintext == "original")
        #expect(!store.isEdited(targetId))
    }

    private func appRecord(
        id: String,
        sender: String,
        plaintext: String,
        kind: UInt64 = MessageSemantics.kindChat,
        tags: [MessageTagFfi] = [],
        at: UInt64
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: id,
            direction: "sent",
            groupIdHex: hex("cc"),
            sender: sender,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            recordedAt: at,
            receivedAt: at
        )
    }

    private func editRecord(
        id: String,
        target: String,
        sender: String,
        text: String,
        at: UInt64
    ) -> AppMessageRecordFfi {
        appRecord(
            id: id,
            sender: sender,
            plaintext: text,
            kind: MessageSemantics.kindEdit,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])],
            at: at
        )
    }

    private func timelineRecord(
        id: String,
        groupId: String,
        sender: String,
        text: String,
        kind: UInt64,
        tags: [MessageTagFfi] = [],
        at: UInt64
    ) -> TimelineMessageRecordFfi {
        TimelineMessageRecordFfi(
            messageIdHex: id,
            sourceMessageIdHex: id,
            direction: "sent",
            groupIdHex: groupId,
            sender: sender,
            plaintext: text,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            timelineAt: at,
            receivedAt: at,
            replyToMessageIdHex: nil,
            replyPreview: nil,
            mediaJson: nil,
            media: [],
            agentTextStreamJson: nil,
            groupSystem: nil,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
            edit: nil,
            deleted: false,
            deletedByMessageIdHex: nil,
            invalidationStatus: nil
        )
    }
}

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}
