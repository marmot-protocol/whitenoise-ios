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
        #expect(ChatRow.previewPresentation(
            for: sentItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(prefix: L10n.string("You"), body: "hello there"))

        let emptySentItem = ChatsListViewModel.Item(
            row: row(
                lastMessage: preview(sender: "self", plaintext: "   ")
            ),
            avatarURL: nil,
            title: "Room"
        )
        #expect(ChatRow.previewPresentation(
            for: emptySentItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: L10n.string("You sent a message")))

        let emptyItem = ChatsListViewModel.Item(row: row(lastMessage: nil), avatarURL: nil, title: "Room")
        #expect(ChatRow.previewPresentation(
            for: emptyItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: L10n.string("No messages yet")))
    }

    @Test func groupPreviewUsesProjectedSenderNameWhileDirectMessageDoesNot() {
        let groupItem = ChatsListViewModel.Item(
            row: row(lastMessage: preview(senderDisplayName: " Alice ")),
            avatarURL: nil,
            title: "Room",
            isDirectMessage: false
        )
        let directItem = ChatsListViewModel.Item(
            row: row(lastMessage: preview(senderDisplayName: "Alice")),
            avatarURL: nil,
            title: "Alice",
            isDirectMessage: true
        )

        #expect(ChatRow.previewPresentation(
            for: groupItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Fallback" }
        ) == ChatRowPreviewPresentation(prefix: "Alice", body: "hello"))
        #expect(ChatRow.previewPresentation(
            for: directItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Fallback" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: "hello"))
    }

    @Test func groupSystemActivityDoesNotAddASenderPrefix() {
        let item = ChatsListViewModel.Item(
            row: row(lastMessage: preview(
                sender: "",
                plaintext: #"{"v":1,"system_type":"member_added","text":"Member added"}"#,
                kind: MessageSemantics.kindGroupSystem
            )),
            avatarURL: nil,
            title: "Room",
            isDirectMessage: false
        )

        #expect(ChatRow.previewPresentation(
            for: item,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: "Member added"))
    }

    @Test func groupSystemPreviewNamesActorAndSubjectFromTheProfileProjection() {
        let actor = hex("aa")
        let subject = hex("bb")
        withAppLanguage(.english) {
            let item = ChatsListViewModel.Item(
                row: row(lastMessage: preview(
                    sender: actor,
                    plaintext: """
                    {"v":1,"system_type":"member_added","text":"Member added",\
                    "data":{"actor":"\(actor)","subject":"\(subject)"}}
                    """,
                    kind: MessageSemantics.kindGroupSystem
                )),
                avatarURL: nil,
                title: "Room",
                isDirectMessage: false,
                systemEventNaming: GroupSystemEventNaming(
                    currentAccountIdHex: hex("cc"),
                    displayName: names
                )
            )

            #expect(item.previewText == "Alice added Bob")
            #expect(ChatRow.previewPresentation(
                for: item,
                activeAccountIdHex: hex("cc"),
                senderName: { _ in "Wrong sender" }
            ) == ChatRowPreviewPresentation(prefix: nil, body: "Alice added Bob"))
        }
    }

    @Test func groupSystemPreviewNamesTheLocalAccountAsYou() {
        let alice = hex("aa")
        let me = hex("cc")
        withAppLanguage(.english) {
            let iAdded = ChatsListViewModel.Item(
                row: row(lastMessage: preview(
                    sender: me,
                    plaintext: """
                    {"v":1,"system_type":"member_added","text":"Member added",\
                    "data":{"actor":"\(me)","subject":"\(alice)"}}
                    """,
                    kind: MessageSemantics.kindGroupSystem
                )),
                avatarURL: nil,
                title: "Room",
                systemEventNaming: GroupSystemEventNaming(currentAccountIdHex: me, displayName: names)
            )
            let iWasAdded = ChatsListViewModel.Item(
                row: row(lastMessage: preview(
                    sender: alice,
                    plaintext: """
                    {"v":1,"system_type":"member_added","text":"Member added",\
                    "data":{"actor":"\(alice)","subject":"\(me)"}}
                    """,
                    kind: MessageSemantics.kindGroupSystem
                )),
                avatarURL: nil,
                title: "Room",
                systemEventNaming: GroupSystemEventNaming(currentAccountIdHex: me, displayName: names)
            )

            #expect(iAdded.previewText == "You added Alice")
            #expect(iWasAdded.previewText == "Alice added you")
        }
    }

    @Test func groupSystemPreviewFallsBackToNpubsWithoutAProjection() {
        let actor = hex("aa")
        let subject = hex("bb")
        withAppLanguage(.english) {
            let item = ChatsListViewModel.Item(
                row: row(lastMessage: preview(
                    sender: actor,
                    plaintext: """
                    {"v":1,"system_type":"member_added","text":"Member added",\
                    "data":{"actor":"\(actor)","subject":"\(subject)"}}
                    """,
                    kind: MessageSemantics.kindGroupSystem
                )),
                avatarURL: nil,
                title: "Room"
            )

            #expect(item.previewText == "npub1424…amrcaj added npub1hwa…xw04hu")
        }
    }

    @Test func groupSystemPreviewUsesTheSenderWhenThePayloadOmitsTheActor() {
        let subject = hex("bb")
        withAppLanguage(.english) {
            let item = ChatsListViewModel.Item(
                row: row(lastMessage: preview(
                    sender: hex("aa"),
                    plaintext: """
                    {"v":1,"system_type":"member_added","text":"Member added",\
                    "data":{"subject":"\(subject)"}}
                    """,
                    kind: MessageSemantics.kindGroupSystem
                )),
                avatarURL: nil,
                title: "Room",
                systemEventNaming: GroupSystemEventNaming(
                    currentAccountIdHex: hex("cc"),
                    displayName: names
                )
            )

            #expect(item.previewText == "Alice added Bob")
        }
    }

    @Test func terminalMembershipReplacesStaleMessagePreview() {
        let leftItem = ChatsListViewModel.Item(
            row: row(lastMessage: preview(), selfMembership: .left),
            avatarURL: nil,
            title: "Room"
        )
        let removedItem = ChatsListViewModel.Item(
            row: row(lastMessage: preview(), selfMembership: .removed),
            avatarURL: nil,
            title: "Room"
        )

        #expect(ChatRow.previewPresentation(
            for: leftItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: L10n.string("You left this chat.")))
        #expect(ChatRow.previewPresentation(
            for: removedItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(
            prefix: nil,
            body: L10n.string("You were removed from this chat.")
        ))
    }

    /// A leave the group has not committed keeps `leaveRequestPending` true
    /// indefinitely, so only a row whose membership has *not* ended may report
    /// the leave as still in flight.
    @Test func onlyAnUnsettledLeavePreviewsAsProgress() {
        let leavingItem = ChatsListViewModel.Item(
            row: row(
                lastMessage: preview(),
                selfMembership: .member,
                leaveRequestPending: true
            ),
            avatarURL: nil,
            title: "Room",
            leaveRequestPending: true
        )
        let departedItem = ChatsListViewModel.Item(
            row: row(
                lastMessage: preview(),
                selfMembership: .left,
                leaveRequestPending: true
            ),
            avatarURL: nil,
            title: "Room",
            leaveRequestPending: true
        )

        #expect(ChatRow.previewPresentation(
            for: leavingItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: L10n.string("Leaving…")))
        #expect(ChatRow.previewPresentation(
            for: departedItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: L10n.string("You left this chat.")))
        #expect(departedItem.departureAction == .deleteLocally)
        #expect(!departedItem.isActiveMember)
    }

    @Test func unansweredInvitePreviewNamesTheInviter() {
        let item = ChatsListViewModel.Item(
            row: row(lastMessage: preview(), pendingConfirmation: true),
            avatarURL: nil,
            title: "Room",
            inviterAccountIdHex: inviterIdHex
        )

        #expect(ChatRow.previewPresentation(
            for: item,
            activeAccountIdHex: "self",
            senderName: { $0 == self.inviterIdHex ? "Alice" : "Wrong account" }
        ) == ChatRowPreviewPresentation(
            prefix: nil,
            body: L10n.formatted("%@ has invited you to a secure chat", "Alice")
        ))
    }

    @Test func unansweredInvitePreviewFallsBackWhenTheInviterIsUnresolved() {
        let item = ChatsListViewModel.Item(
            row: row(lastMessage: nil, pendingConfirmation: true),
            avatarURL: nil,
            title: "Room"
        )

        #expect(ChatRow.previewPresentation(
            for: item,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong account" }
        ) == ChatRowPreviewPresentation(
            prefix: nil,
            body: L10n.formatted(
                "%@ has invited you to a secure chat",
                L10n.string("Someone")
            )
        ))
    }

    @Test func answeredChatKeepsItsMessagePreview() {
        let item = ChatsListViewModel.Item(
            row: row(lastMessage: preview(), pendingConfirmation: false),
            avatarURL: nil,
            title: "Room",
            inviterAccountIdHex: inviterIdHex
        )

        #expect(ChatRow.previewPresentation(
            for: item,
            activeAccountIdHex: "self",
            senderName: { _ in "Alice" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: "hello"))
    }

    @Test func terminalMembershipOutranksAPendingInvite() {
        let removed = ChatsListViewModel.Item(
            row: row(selfMembership: .removed, pendingConfirmation: true),
            avatarURL: nil,
            title: "Room",
            inviterAccountIdHex: inviterIdHex
        )
        let left = ChatsListViewModel.Item(
            row: row(selfMembership: .left, pendingConfirmation: true),
            avatarURL: nil,
            title: "Room",
            inviterAccountIdHex: inviterIdHex
        )
        let leaving = ChatsListViewModel.Item(
            row: row(leaveRequestPending: true, pendingConfirmation: true),
            avatarURL: nil,
            title: "Room",
            inviterAccountIdHex: inviterIdHex,
            leaveRequestPending: true
        )

        #expect(ChatRow.previewPresentation(
            for: removed,
            activeAccountIdHex: "self",
            senderName: { _ in "Alice" }
        ) == ChatRowPreviewPresentation(
            prefix: nil,
            body: L10n.string("You were removed from this chat.")
        ))
        #expect(ChatRow.previewPresentation(
            for: left,
            activeAccountIdHex: "self",
            senderName: { _ in "Alice" }
        ) == ChatRowPreviewPresentation(
            prefix: nil,
            body: L10n.string("You left this chat.")
        ))
        #expect(ChatRow.previewPresentation(
            for: leaving,
            activeAccountIdHex: "self",
            senderName: { _ in "Alice" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: L10n.string("Leaving…")))
    }

    @Test func inviterResolutionPrefersTheWelcomerAndOnlyAppliesWhilePending() {
        #expect(ChatsListViewModel.inviterAccountIdHex(
            pendingConfirmation: true,
            welcomerAccountIdHex: " ABCD ",
            directPeerAccountIdHex: "beef"
        ) == "abcd")
        #expect(ChatsListViewModel.inviterAccountIdHex(
            pendingConfirmation: true,
            welcomerAccountIdHex: "   ",
            directPeerAccountIdHex: "BEEF"
        ) == "beef")
        #expect(ChatsListViewModel.inviterAccountIdHex(
            pendingConfirmation: true,
            welcomerAccountIdHex: nil,
            directPeerAccountIdHex: nil
        ) == nil)
        #expect(ChatsListViewModel.inviterAccountIdHex(
            pendingConfirmation: false,
            welcomerAccountIdHex: "abcd",
            directPeerAccountIdHex: "beef"
        ) == nil)
    }

    @Test func projectedGroupCarriesTheInviterIntoTheConversation() {
        let item = ChatsListViewModel.Item(
            row: row(pendingConfirmation: true),
            avatarURL: nil,
            title: "Room",
            inviterAccountIdHex: inviterIdHex
        )

        #expect(item.projectedGroup.welcomerAccountIdHex == inviterIdHex)
        #expect(item.projectedGroup.pendingConfirmation)
    }

    private let inviterIdHex = String(repeating: "a4", count: 32)

    @Test func inviterReadPlanSkipsGroupsWhoseLookupAlreadyCompleted() {
        let groupIds = [hex("aa"), hex("bb")]
        let pendingInviteGroupIds = Set(groupIds)

        let firstPass = ChatsListViewModel.inviterReadPlan(
            groupIds: groupIds,
            pendingInviteGroupIds: pendingInviteGroupIds,
            resolvedInviterGroupIds: [],
            completedLookupGroupIds: [],
            knownPeerGroupIds: [],
            limit: 8
        )

        #expect(firstPass.read == groupIds)
        #expect(firstPass.deferred.isEmpty)

        let secondPass = ChatsListViewModel.inviterReadPlan(
            groupIds: groupIds,
            pendingInviteGroupIds: pendingInviteGroupIds,
            resolvedInviterGroupIds: [],
            completedLookupGroupIds: Set(groupIds),
            knownPeerGroupIds: [],
            limit: 8
        )

        #expect(secondPass.read.isEmpty)
        #expect(secondPass.deferred.isEmpty)
    }

    @Test func inviterReadPlanDefersInvitesPastTheBatchLimitAndDrainsThem() {
        let groupIds = (0 ..< 20).map { String(format: "%064x", $0) }
        let pendingInviteGroupIds = Set(groupIds)
        var completedLookupGroupIds: Set<String> = []
        var readCounts: [Int] = []
        var deferredCounts: [Int] = []

        while true {
            let plan = ChatsListViewModel.inviterReadPlan(
                groupIds: groupIds,
                pendingInviteGroupIds: pendingInviteGroupIds,
                resolvedInviterGroupIds: [],
                completedLookupGroupIds: completedLookupGroupIds,
                knownPeerGroupIds: [],
                limit: 8
            )
            if plan.read.isEmpty {
                #expect(plan.deferred.isEmpty)
                break
            }
            readCounts.append(plan.read.count)
            deferredCounts.append(plan.deferred.count)
            completedLookupGroupIds.formUnion(plan.read)
        }

        #expect(readCounts == [8, 8, 4])
        #expect(deferredCounts == [12, 4, 0])
        #expect(completedLookupGroupIds == pendingInviteGroupIds)
    }

    @Test func inviterLookupStopsRetryingAfterRepeatedFailures() {
        #expect(ChatsListViewModel.shouldRetryInviterLookup(failureCount: 1))
        #expect(ChatsListViewModel.shouldRetryInviterLookup(failureCount: 2))
        #expect(!ChatsListViewModel.shouldRetryInviterLookup(failureCount: 3))
        #expect(!ChatsListViewModel.shouldRetryInviterLookup(failureCount: 4))
    }

    @Test func inviterReadPlanSkipsAnsweredResolvedAndAlreadyPeeredInvites() {
        let peerKnown = hex("aa")
        let needsRead = hex("bb")
        let answered = hex("cc")
        let alreadyResolved = hex("dd")

        let plan = ChatsListViewModel.inviterReadPlan(
            groupIds: [peerKnown, needsRead, answered, alreadyResolved],
            pendingInviteGroupIds: [peerKnown, needsRead, alreadyResolved],
            resolvedInviterGroupIds: [alreadyResolved],
            completedLookupGroupIds: [],
            knownPeerGroupIds: [peerKnown],
            limit: 8
        )

        #expect(plan.read == [needsRead])
        #expect(plan.deferred.isEmpty)
    }

    private func row(
        groupIdHex: String = "0123456789abcdef",
        title: String = "Room",
        lastMessage: ChatListMessagePreviewFfi? = nil,
        selfMembership: SelfMembershipFfi = .member,
        leaveRequestPending: Bool = false,
        pendingConfirmation: Bool = false
    ) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: false,
            pendingConfirmation: pendingConfirmation,
            title: title,
            groupName: title,
            avatarUrl: nil,
            avatar: nil,
            lastMessage: lastMessage,
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
            selfMembership: selfMembership,
            conversationKind: .group,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestPending ? 1_000 : nil
        )
    }

    private func preview(
        messageIdHex: String = "01",
        sender: String = "sender",
        senderDisplayName: String? = nil,
        plaintext: String = "hello",
        contentTokens: MarkdownDocumentFfi = MarkdownDocumentFfi(blocks: [], truncated: false),
        kind: UInt64 = MessageSemantics.kindChat,
        timelineAt: UInt64 = 1,
        deleted: Bool = false
    ) -> ChatListMessagePreviewFfi {
        ChatListMessagePreviewFfi(
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

    private func hex(_ byte: String) -> String {
        String(repeating: byte, count: 32)
    }

    private func names(_ accountIdHex: String) -> String {
        switch accountIdHex.prefix(2) {
        case "aa": "Alice"
        case "bb": "Bob"
        default: IdentityFormatter.short(accountIdHex)
        }
    }
}
