import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct ChatsListProjectionTests {

    @Test func directPeerProjectionRequiresExactlySelfAndOneOtherMember() {
        let me = hex("01")
        let other = hex("02")

        #expect(ChatsListViewModel.directPeerAccountId(
            memberIdsHex: [me.uppercased(), other],
            myAccountIdHex: me
        ) == other)
        #expect(ChatsListViewModel.directPeerAccountId(
            memberIdsHex: [me, other, hex("03")],
            myAccountIdHex: me
        ) == nil)
        #expect(ChatsListViewModel.directPeerAccountId(
            memberIdsHex: [other, hex("03")],
            myAccountIdHex: me
        ) == nil)
    }

    @Test func projectedRowsDriveActiveArchivedUnreadAndOrdering() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let older = chatListRow(
            groupIdHex: hex("a1"),
            title: "Older",
            lastMessage: chatListPreview(messageIdHex: hex("b1"), plaintext: "older", timelineAt: 10),
            updatedAt: 10
        )
        let newerUnread = chatListRow(
            groupIdHex: hex("a2"),
            title: "Newer",
            lastMessage: chatListPreview(messageIdHex: hex("b2"), plaintext: "newer", timelineAt: 20),
            unreadCount: 3,
            firstUnreadMessageIdHex: hex("c2"),
            updatedAt: 20
        )
        let archived = chatListRow(
            groupIdHex: hex("a3"),
            archived: true,
            title: "Archived",
            lastMessage: chatListPreview(messageIdHex: hex("b3"), plaintext: "archived", timelineAt: 30),
            updatedAt: 30
        )

        viewModel.applyChatListSnapshot([older, archived, newerUnread])

        #expect(viewModel.items.map(\.id) == [newerUnread.groupIdHex, older.groupIdHex])
        #expect(viewModel.archivedItems.map(\.id) == [archived.groupIdHex])
        #expect(viewModel.items.first?.title == "Newer")
        #expect(viewModel.items.first?.previewText == "newer")
        #expect(viewModel.items.first?.unreadCount == 3)
        #expect(viewModel.items.first?.firstUnreadMessageIdHex == hex("c2"))
    }

    @Test func projectedRowsUseDurableActivityOrderingAfterPreviewPruning() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let prunedButNewer = chatListRow(
            groupIdHex: hex("a1"),
            title: "Pruned",
            activitySortAt: 30,
            updatedAt: 40
        )
        let previewButOlder = chatListRow(
            groupIdHex: hex("a2"),
            title: "Preview",
            lastMessage: chatListPreview(messageIdHex: hex("b2"), plaintext: "visible", timelineAt: 20),
            activitySortAt: 20,
            updatedAt: 50
        )

        viewModel.applyChatListSnapshot([previewButOlder, prunedButNewer])

        #expect(viewModel.items.map(\.id) == [prunedButNewer.groupIdHex, previewButOlder.groupIdHex])
    }

    @Test func pinnedRowsLeadInManualPositionOrderBeforeRecentChats() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let firstPin = chatListRow(
            groupIdHex: hex("a1"),
            pinned: true,
            pinnedPosition: 0,
            title: "First pin",
            activitySortAt: 10
        )
        let secondPin = chatListRow(
            groupIdHex: hex("a2"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second pin",
            activitySortAt: 20
        )
        let recent = chatListRow(
            groupIdHex: hex("a3"),
            title: "Recent",
            activitySortAt: 100
        )

        viewModel.applyChatListSnapshot([recent, secondPin, firstPin])

        #expect(viewModel.items.map(\.id) == [
            firstPin.groupIdHex,
            secondPin.groupIdHex,
            recent.groupIdHex,
        ])
        #expect(viewModel.items.first?.isPinned == true)
    }

    @Test func authoritativePinOrderReordersPinsAndClearsPinsOmittedFromState() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let first = chatListRow(
            groupIdHex: hex("a1"),
            pinned: true,
            pinnedPosition: 0,
            title: "First",
            activitySortAt: 10
        )
        let second = chatListRow(
            groupIdHex: hex("a2"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second",
            activitySortAt: 20
        )
        let newlyPinned = chatListRow(
            groupIdHex: hex("a3"),
            title: "Third",
            activitySortAt: 30
        )
        viewModel.applyChatListSnapshot([first, second, newlyPinned])

        viewModel.applyPinnedOrder([
            newlyPinned.groupIdHex,
            second.groupIdHex,
        ])

        #expect(viewModel.items.map(\.id) == [
            newlyPinned.groupIdHex,
            second.groupIdHex,
            first.groupIdHex,
        ])
        #expect(viewModel.item(groupIdHex: newlyPinned.groupIdHex)?.row.pinnedPosition == 0)
        #expect(viewModel.item(groupIdHex: second.groupIdHex)?.row.pinnedPosition == 1)
        #expect(viewModel.item(groupIdHex: first.groupIdHex)?.isPinned == false)
        #expect(viewModel.item(groupIdHex: first.groupIdHex)?.row.pinnedPosition == nil)
    }

    @Test func pinOrderSnapshotWaitsForSwipeDrawerTransitionToFinish() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let first = chatListRow(
            groupIdHex: hex("a1"),
            pinned: true,
            pinnedPosition: 0,
            title: "First"
        )
        let second = chatListRow(
            groupIdHex: hex("a2"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second"
        )
        viewModel.applyChatListSnapshot([first, second])

        var reorderedFirst = first
        reorderedFirst.pinnedPosition = 1
        var reorderedSecond = second
        reorderedSecond.pinnedPosition = 0
        let transitionID = viewModel.beginPinOrderUITransition()
        viewModel.applyPresentedSnapshot(presentedChatSnapshot([reorderedSecond, reorderedFirst]))

        #expect(viewModel.items.map(\.id) == [first.groupIdHex, second.groupIdHex])

        let applied = viewModel.finishPinOrderUITransition(
            transitionID: transitionID,
            orderedGroupIds: [second.groupIdHex, first.groupIdHex]
        )

        #expect(applied)
        #expect(viewModel.items.map(\.id) == [second.groupIdHex, first.groupIdHex])
    }

    @Test func pinOrderSubscriptionSnapshotAtomicallyReplacesRowsAndPendingUpdates() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let first = chatListRow(
            groupIdHex: hex("a1"),
            pinned: true,
            pinnedPosition: 0,
            title: "First",
            updatedAt: 10
        )
        let second = chatListRow(
            groupIdHex: hex("a2"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second",
            updatedAt: 10
        )
        let removed = chatListRow(groupIdHex: hex("a3"), title: "Removed", updatedAt: 10)
        viewModel.applyChatListSnapshot([first, second, removed])
        viewModel.enqueueChatListRowUpdate(chatListRow(
            groupIdHex: first.groupIdHex,
            pinned: true,
            pinnedPosition: 0,
            title: "Stale pending",
            updatedAt: 20
        ))

        let reorderedFirst = chatListRow(
            groupIdHex: first.groupIdHex,
            pinned: true,
            pinnedPosition: 1,
            title: "First",
            updatedAt: 10
        )
        let reorderedSecond = chatListRow(
            groupIdHex: second.groupIdHex,
            pinned: true,
            pinnedPosition: 0,
            title: "Second",
            updatedAt: 10
        )
        viewModel.applyPresentedSnapshot(presentedChatSnapshot([reorderedFirst, reorderedSecond]))

        #expect(viewModel.items.map(\.id) == [second.groupIdHex, first.groupIdHex])
        #expect(viewModel.items.last?.title == "First")
        #expect(viewModel.item(groupIdHex: removed.groupIdHex) == nil)
    }

    @Test func successfulSnapshotClearsPreviousLoadError() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(groupIdHex: hex("a1"), title: "Recovered", updatedAt: 10)

        viewModel.setLoadErrorForTesting("Couldn't load chats")
        viewModel.applyChatListSnapshot([row])

        #expect(viewModel.loadError == nil)
        #expect(viewModel.items.map(\.id) == [row.groupIdHex])
    }

    @Test func presentedSnapshotReplacesQueuedRowEvenWithOlderTimestamp() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let groupId = hex("a8")
        let stale = chatListRow(
            groupIdHex: groupId,
            title: "Stale",
            unreadCount: 1,
            updatedAt: 10
        )
        let fresh = chatListRow(
            groupIdHex: groupId,
            title: "Fresh",
            unreadCount: 4,
            updatedAt: 20
        )

        viewModel.enqueueChatListRowUpdate(fresh)
        viewModel.applyPresentedSnapshot(presentedChatSnapshot([stale]))

        #expect(viewModel.items.first?.title == "Stale")
        #expect(viewModel.items.first?.unreadCount == 1)
    }

    @Test func visibleRowsRevisionAdvancesOnlyForPublishedCollectionChanges() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(groupIdHex: hex("a9"), title: "Stable", updatedAt: 10)

        #expect(viewModel.visibleRowsRevision == 0)
        viewModel.applyChatListSnapshot([row])
        #expect(viewModel.visibleRowsRevision == 1)
        viewModel.applyChatListSnapshot([row])
        #expect(viewModel.visibleRowsRevision == 1)
    }

    @Test func itemByGroupIdAccessorResolvesActiveAndArchivedRowsAndMissesUnknownId() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let active = chatListRow(groupIdHex: hex("a1"), title: "Active", updatedAt: 10)
        let archived = chatListRow(groupIdHex: hex("a2"), archived: true, title: "Archived", updatedAt: 20)

        viewModel.applyChatListSnapshot([active, archived])

        // The accessor resolves a row by id regardless of which published
        // array it lands in, and returns nil for an unknown id — matching the
        // old `(items + archivedItems).first(where:)` scan it replaces.
        #expect(viewModel.item(groupIdHex: active.groupIdHex)?.id == active.groupIdHex)
        #expect(viewModel.item(groupIdHex: active.groupIdHex)?.isArchived == false)
        #expect(viewModel.item(groupIdHex: archived.groupIdHex)?.id == archived.groupIdHex)
        #expect(viewModel.item(groupIdHex: archived.groupIdHex)?.isArchived == true)
        #expect(viewModel.item(groupIdHex: hex("ff")) == nil)
    }

    @Test func previewTextSanitizesProjectedLastMessage() throws {
        let unsafe = chatListRow(
            groupIdHex: hex("d0"),
            title: "Unsafe",
            lastMessage: chatListPreview(
                messageIdHex: hex("d1"),
                plaintext: " hello\u{202E}\nthere\u{200B} ",
                timelineAt: 1
            )
        )

        let item = ChatsListViewModel.Item(row: unsafe, avatarURL: nil, title: "Unsafe")

        #expect(item.previewText == "hello there")
    }

    @Test func itemAvatarURLUsesProjectedGroupAvatarURL() throws {
        let item = ChatsListViewModel.Item(
            row: chatListRow(groupIdHex: hex("d4"), title: "Avatar"),
            avatarURL: URL(string: "https://cdn.example.com/group.png"),
            title: "Avatar"
        )

        #expect(item.avatarURL?.absoluteString == "https://cdn.example.com/group.png")
    }

    @Test func chatRowsDoNotFetchAvatarsBeforeInviteConfirmation() throws {
        let avatarURL = try #require(URL(string: "https://cdn.example.com/group.png"))

        #expect(ChatRow.automaticAvatarURL(avatarURL, pendingConfirmation: true) == nil)
        #expect(
            ChatRow.automaticAvatarURL(avatarURL, pendingConfirmation: false) == avatarURL
        )
    }

    @Test func itemSurfacesUnreadMentionProjection() throws {
        let item = ChatsListViewModel.Item(
            row: chatListRow(
                groupIdHex: hex("de"),
                title: "Mentions",
                unreadCount: 4,
                unreadMentionCount: 2,
                unreadMention: true
            ),
            avatarURL: nil,
            title: "Mentions"
        )

        #expect(item.hasUnreadMention)
        #expect(item.unreadMentionCount == 2)
    }

    @Test func draftPreviewOverridesTheLastMessageAndParticipatesInSearch() {
        let item = ChatsListViewModel.Item(
            row: chatListRow(
                groupIdHex: hex("df"),
                title: "Drafts",
                lastMessage: chatListPreview(
                    messageIdHex: hex("e0"),
                    plaintext: "older message",
                    timelineAt: 10
                )
            ),
            avatarURL: nil,
            title: "Drafts",
            draftSummary: MessageDraftSummaryFfi(
                groupIdHex: hex("df"),
                content: "  Follow up\nwith Alice  ",
                replyToMessageIdHex: nil,
                mediaAttachments: [],
                createdAtMs: 1,
                updatedAtMs: 1
            )
        )

        #expect(item.draftPreview == "Follow up with Alice")
        #expect(item.searchHaystack.contains("follow up with alice"))
        #expect(ChatRow.previewPresentation(
            for: item,
            activeAccountIdHex: nil,
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(
            prefix: nil,
            body: L10n.formatted("Draft: %@", "Follow up with Alice")
        ))
    }

    @MainActor
    @Test func chatListDisplayTitleUsesGroupDisplayForUnnamedDirectMessage() throws {
        let appState = AppState.test()
        let me = hex("11")
        let other = hex("22")
        let groupId = hex("aa")
        let row = chatListRow(
            groupIdHex: groupId,
            title: groupId,
            groupName: ""
        )
        let details = GroupDetailsFfi(
            group: group(name: "", id: groupId),
            members: [
                groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                groupMember(memberIdHex: other, isAdmin: false, isSelf: false),
            ]
        )

        let title = ChatsListViewModel.displayTitle(
            for: row,
            details: details,
            appState: appState
        )

        #expect(title == appState.shortNpub(forAccountIdHex: other))
    }

    @MainActor
    @Test func chatListDisplayUsesPeerAvatarSeedForUnnamedDirectMessage() throws {
        let appState = AppState.test()
        let me = hex("31")
        let other = hex("32")
        let groupId = hex("ab")
        let row = chatListRow(groupIdHex: groupId, title: groupId, groupName: "")
        let details = GroupDetailsFfi(
            group: group(name: "", id: groupId),
            members: [
                groupMember(memberIdHex: me, isAdmin: true, isSelf: true),
                groupMember(memberIdHex: other, isAdmin: false, isSelf: false),
            ]
        )

        let display = ChatsListViewModel.display(for: row, details: details, appState: appState)

        #expect(display.avatarSeed == other)
        #expect(display.avatarSeed != groupId)
    }

    @Test func cachedDirectPeerResolvesAnUnnamedDirectRowWithoutGroupDetails() throws {
        let appState = AppState.test()
        let other = hex("33")
        let groupId = hex("ac")
        let avatar = "https://cdn.example.com/alice.png"
        appState.profileStore.profileProjectionCache[other] = ProfileDisplayProjection(
            profile: UserProfileMetadataFfi(
                name: nil,
                displayName: "Alice",
                about: nil,
                picture: avatar,
                banner: nil,
                nip05: nil,
                lud16: nil
            ),
            projectedName: nil,
            localAccountLabel: nil
        )
        let row = chatListRow(
            groupIdHex: groupId,
            title: groupId,
            groupName: "",
            conversationKind: .direct
        )

        let display = ChatsListViewModel.display(
            for: row,
            details: nil,
            appState: appState,
            cachedDirectPeerAccountId: other
        )

        #expect(display.title == "Alice")
        #expect(display.avatarURL?.absoluteString == avatar)
        #expect(display.avatarSeed == other)
        #expect(display.isDirectMessage == true)
        #expect(display.directPeerAccountIdHex == other)
    }

    @Test func unresolvedDirectRowNeverExposesItsInternalGroupHexAsAUserIdentity() throws {
        let appState = AppState.test()
        let groupId = hex("ad")
        let row = chatListRow(
            groupIdHex: groupId,
            title: groupId,
            groupName: "",
            conversationKind: .direct
        )

        let display = ChatsListViewModel.display(for: row, details: nil, appState: appState)

        #expect(display.title == L10n.string("Direct message"))
        #expect(display.title != IdentityFormatter.short(groupId))
        #expect(display.directPeerAccountIdHex == nil)
    }

    @Test func directPeerCacheIsAccountScopedBoundedAndKeepsRecentDirectRows() {
        let olderDirect = chatListRow(
            groupIdHex: hex("b1"),
            title: "Older direct",
            activitySortAt: 10,
            conversationKind: .direct
        )
        let newerDirect = chatListRow(
            groupIdHex: hex("b2"),
            title: "Newer direct",
            activitySortAt: 20,
            conversationKind: .direct
        )
        let group = chatListRow(
            groupIdHex: hex("b3"),
            title: "Group",
            activitySortAt: 30,
            conversationKind: .group
        )
        var cache = ChatListDirectPeerCache(maxAccounts: 2, maxGroupsPerAccount: 1)

        cache.store(
            accountRef: "alice",
            peersByGroupId: [
                olderDirect.groupIdHex: hex("41"),
                newerDirect.groupIdHex: hex("42"),
                group.groupIdHex: hex("43"),
            ],
            rowsByGroupId: [
                olderDirect.groupIdHex: olderDirect,
                newerDirect.groupIdHex: newerDirect,
                group.groupIdHex: group,
            ]
        )

        #expect(cache.restore(accountRef: "bob").isEmpty)
        #expect(cache.restore(accountRef: "alice") == [newerDirect.groupIdHex: hex("42")])
    }

    @Test func emptyPartialBindDoesNotEraseRetainedDirectPeerMappings() {
        let row = chatListRow(
            groupIdHex: hex("b4"),
            title: "Direct",
            activitySortAt: 20,
            conversationKind: .direct
        )
        let peer = hex("44")
        var cache = ChatListDirectPeerCache()
        cache.store(
            accountRef: "alice",
            peersByGroupId: [row.groupIdHex: peer],
            rowsByGroupId: [row.groupIdHex: row]
        )

        cache.store(accountRef: "alice", peersByGroupId: [:], rowsByGroupId: [:])

        #expect(cache.restore(accountRef: "alice") == [row.groupIdHex: peer])
    }

    @Test func chatListEnrichmentPrioritizesPinnedThenRecentVisibleRows() {
        let firstPin = chatListRow(
            groupIdHex: hex("b5"),
            pinned: true,
            pinnedPosition: 0,
            title: "First pin",
            activitySortAt: 1
        )
        let secondPin = chatListRow(
            groupIdHex: hex("b6"),
            pinned: true,
            pinnedPosition: 1,
            title: "Second pin",
            activitySortAt: 100
        )
        let recent = chatListRow(
            groupIdHex: hex("b7"),
            title: "Recent",
            activitySortAt: 50
        )
        let older = chatListRow(
            groupIdHex: hex("b8"),
            title: "Older",
            activitySortAt: 10
        )
        let rows = [firstPin, secondPin, recent, older]
        let rowsByGroupId = Dictionary(uniqueKeysWithValues: rows.map { ($0.groupIdHex, $0) })

        let prioritized = ChatsListViewModel.prioritizedEnrichmentGroupIds(
            Set(rowsByGroupId.keys),
            rowsByGroupId: rowsByGroupId
        )

        #expect(prioritized == rows.map(\.groupIdHex))
    }

    @Test func itemAvatarURLRejectsUnsafeProjectedGroupAvatarURL() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(groupIdHex: hex("d5"), title: "Unsafe Avatar")
        viewModel.applyChatListSnapshot([row])

        // The same path keeps a public HTTPS URL (localGroupChangeUpdatesProjectedAvatarURL).
        viewModel.applyLocalGroupChange(group(
            name: "Unsafe Avatar",
            id: row.groupIdHex,
            avatarUrl: "https://127.0.0.1/private.png"
        ))

        #expect(viewModel.items.map(\.id) == [row.groupIdHex])
        #expect(viewModel.items.first?.avatarURL == nil)
    }

    @Test func localArchiveChangeMovesProjectedRowBetweenScopes() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(groupIdHex: hex("d1"), title: "General")
        viewModel.applyChatListSnapshot([row])

        viewModel.applyLocalGroupChange(group(name: "General", id: row.groupIdHex, archived: true))

        #expect(viewModel.items.isEmpty)
        #expect(viewModel.archivedItems.map(\.id) == [row.groupIdHex])
        #expect(viewModel.archivedItems.first?.isArchived == true)
    }

    @Test func localGroupChangeUpdatesProjectedAvatarURL() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(groupIdHex: hex("d6"), title: "General")
        viewModel.applyChatListSnapshot([row])

        viewModel.applyLocalGroupChange(group(
            name: "General",
            id: row.groupIdHex,
            avatarUrl: "https://cdn.example.com/group.png"
        ))

        #expect(viewModel.items.first?.avatarURL?.absoluteString == "https://cdn.example.com/group.png")
    }

    @Test func localGroupChangeRefreshesCachedGroupDetailsDisplay() throws {
        let groupId = hex("d8")
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(groupIdHex: groupId, title: groupId, groupName: "")
        viewModel.applyChatListSnapshot([row])
        viewModel.seedGroupDetailsCacheForTesting(GroupDetailsFfi(
            group: group(name: "Old name", id: groupId, avatarUrl: "https://cdn.example.com/old.png"),
            members: [groupMember(memberIdHex: hex("11"), isAdmin: true, isSelf: true)]
        ))

        viewModel.applyLocalGroupChange(group(
            name: "New name",
            id: groupId,
            avatarUrl: "https://cdn.example.com/new.png"
        ))

        #expect(viewModel.items.first?.title == "New name")
        #expect(viewModel.items.first?.avatarURL?.absoluteString == "https://cdn.example.com/new.png")
    }

    @Test func chatListRowRefreshesCachedGroupDetailsDisplay() throws {
        let groupId = hex("d9")
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let oldRow = chatListRow(
            groupIdHex: groupId,
            title: "Old name",
            groupName: "Old name",
            avatarUrl: "https://cdn.example.com/old.png"
        )
        viewModel.applyChatListSnapshot([oldRow])
        viewModel.seedGroupDetailsCacheForTesting(GroupDetailsFfi(
            group: group(name: "Old name", id: groupId, avatarUrl: "https://cdn.example.com/old.png"),
            members: [groupMember(memberIdHex: hex("11"), isAdmin: true, isSelf: true)]
        ))

        viewModel.applyChatListRow(chatListRow(
            groupIdHex: groupId,
            title: "New name",
            groupName: "New name",
            avatarUrl: "https://cdn.example.com/new.png"
        ))

        #expect(viewModel.items.first?.title == "New name")
        #expect(viewModel.items.first?.avatarURL?.absoluteString == "https://cdn.example.com/new.png")
    }

    @Test func liveRowWithoutNameOrAvatarKeepsEnrichedGroupDetails() throws {
        let groupId = hex("da")
        let viewModel = ChatsListViewModel(appState: AppState.test())
        viewModel.applyChatListSnapshot([chatListRow(groupIdHex: groupId, title: "Enriched name", groupName: "")])
        viewModel.seedGroupDetailsCacheForTesting(GroupDetailsFfi(
            group: group(name: "Enriched name", id: groupId, avatarUrl: "https://cdn.example.com/enriched.png"),
            members: [groupMember(memberIdHex: hex("11"), isAdmin: true, isSelf: true)]
        ))

        // A routine live update (new message / unread change) carries neither
        // a name nor an avatar; it must not wipe the enriched values.
        viewModel.applyChatListRow(chatListRow(
            groupIdHex: groupId,
            title: groupId,
            groupName: "",
            avatarUrl: nil,
            unreadCount: 1
        ))

        let cached = viewModel.groupDetailsCacheEntryForTesting(groupIdHex: groupId)
        #expect(cached?.group.name == "Enriched name")
        #expect(cached?.group.avatarUrl == "https://cdn.example.com/enriched.png")
        #expect(viewModel.items.first?.avatarURL?.absoluteString == "https://cdn.example.com/enriched.png")
        #expect(viewModel.items.first?.unreadCount == 1)
    }

    @Test func profileRefreshRebuildsNamedGroupMentionPreviews() throws {
        let bech32 = "npub1" + String(repeating: "q", count: 58)
        let tokens = MarkdownDocumentFfi(blocks: [
            .paragraph(inlines: [
                .text(content: "ping "),
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32)),
            ]),
        ], truncated: false)
        let viewModel = ChatsListViewModel(appState: AppState.test())
        viewModel.mentionDisplayNameForTesting = { _ in nil }
        let row = chatListRow(
            groupIdHex: hex("da"),
            title: "Named room",
            groupName: "Named room",
            lastMessage: chatListPreview(
                messageIdHex: hex("db"),
                plaintext: "fallback",
                contentTokens: tokens
            )
        )
        viewModel.applyChatListSnapshot([row])

        #expect(viewModel.items.first?.previewText == "ping @npub1qqq…qqqq")

        viewModel.mentionDisplayNameForTesting = { _ in "Alice" }
        viewModel.refreshDisplayProjections()

        #expect(viewModel.items.first?.previewText == "ping @Alice")
    }

    @Test func localGroupChangeUpdatesProjectedMembership() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(groupIdHex: hex("d7"), title: "General")
        viewModel.applyChatListSnapshot([row])

        viewModel.applyLocalGroupChange(group(
            name: "General",
            id: row.groupIdHex,
            selfMembership: .removed
        ))

        #expect(viewModel.items.first?.selfMembership == .removed)
        #expect(viewModel.items.first?.isActiveMember == false)
    }

    @Test func markGroupLeftPreservesInactiveHistoryRow() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(groupIdHex: hex("df"), title: "Left group")
        viewModel.applyChatListSnapshot([row])

        viewModel.markGroupLeft(groupIdHex: row.groupIdHex)

        #expect(viewModel.items.map(\.id) == [row.groupIdHex])
        #expect(viewModel.items.first?.leaveRequestPending == true)
        // Marmot records the voluntary departure at leave time, so the optimistic
        // row must too: a row left claiming an active membership can never offer
        // the local delete that clears an uncommitted leave.
        #expect(viewModel.items.first?.selfMembership == .left)
        #expect(viewModel.items.first?.isActiveMember == false)
        #expect(viewModel.items.first?.departureStatus == .membershipEnded(.left))
        #expect(viewModel.items.first?.departureAction == .deleteLocally)
    }

    @Test func durableMemberPendingLeaveSurvivesFreshSnapshot() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let groupId = hex("e1")
        viewModel.applyChatListSnapshot([
            chatListRow(
                groupIdHex: groupId,
                title: "Leaving group",
                updatedAt: 20,
                selfMembership: .member,
                leaveRequestPending: true
            )
        ])

        #expect(viewModel.items.first?.leaveRequestPending == true)
        #expect(viewModel.items.first?.selfMembership == .member)
        #expect(viewModel.items.first?.isActiveMember == false)
    }

    @Test func resolvedTerminalMembershipClearsPendingLeave() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let groupId = hex("e2")

        viewModel.applyChatListSnapshot([
            chatListRow(
                groupIdHex: groupId,
                title: "Left group",
                updatedAt: 20,
                selfMembership: .left
            )
        ])

        #expect(viewModel.items.first?.leaveRequestPending == false)
        #expect(viewModel.items.first?.selfMembership == .left)
        #expect(viewModel.items.first?.isActiveMember == false)
    }

    @Test func publishedLeaveCanRemainDurablyPending() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(
            groupIdHex: hex("e3"),
            title: "Leaving group",
            selfMembership: .left,
            leaveRequestPending: true
        )

        viewModel.applyChatListSnapshot([row])

        #expect(viewModel.items.first?.leaveRequestPending == true)
        #expect(viewModel.items.first?.selfMembership == .left)
        #expect(viewModel.items.first?.isActiveMember == false)
        // The durable state a quiet group leaves behind forever: it must read as
        // a settled departure with the local delete available, not as progress.
        #expect(viewModel.items.first?.departureStatus == .membershipEnded(.left))
        #expect(viewModel.items.first?.departureAction == .deleteLocally)
        #expect(
            ChatRow.previewPresentation(
                for: try #require(viewModel.items.first),
                activeAccountIdHex: nil,
                senderName: { $0 }
            ).body == "You left this chat."
        )
    }

    @Test func presentedSnapshotDropsAbsentProjectedRow() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let kept = chatListRow(groupIdHex: hex("d1"), title: "Keep")
        let removed = chatListRow(groupIdHex: hex("d2"), title: "Remove")
        viewModel.applyChatListSnapshot([kept, removed])

        viewModel.applyPresentedSnapshot(presentedChatSnapshot([kept]))

        #expect(viewModel.items.map(\.id) == [kept.groupIdHex])
        #expect(viewModel.archivedItems.isEmpty)
    }

    @Test func intersectingDictionaryKeepsOnlySurvivingKeys() throws {
        let cache = ["a": 1, "b": 2, "c": 3]
        let pruned = ChatsListViewModel.intersecting(cache, with: ["a", "c", "z"])

        #expect(pruned == ["a": 1, "c": 3])
    }

    @Test func intersectingSetKeepsOnlySurvivingMembers() throws {
        let ids: Set<String> = ["a", "b", "c"]
        let pruned = ChatsListViewModel.intersecting(ids, with: ["b", "z"])

        #expect(pruned == ["b"])
    }

    @Test func intersectingDropsEverythingWhenNothingSurvives() throws {
        #expect(ChatsListViewModel.intersecting(["a": 1, "b": 2], with: []).isEmpty)
        #expect(ChatsListViewModel.intersecting(Set(["a", "b"]), with: []).isEmpty)
    }

    @Test func intersectingKeepsEverythingWhenAllSurvive() throws {
        let cache = ["a": 1, "b": 2]
        #expect(ChatsListViewModel.intersecting(cache, with: ["a", "b"]) == cache)
    }

    @Test func chatListSubscriptionRetryDelayDoublesUntilCapped() {
        #expect(ChatsListViewModel.nextLiveSubscriptionRetryDelay(after: 500_000_000) == 1_000_000_000)
        #expect(ChatsListViewModel.nextLiveSubscriptionRetryDelay(after: 4_000_000_000) == 8_000_000_000)
        #expect(ChatsListViewModel.nextLiveSubscriptionRetryDelay(after: 8_000_000_000) == 8_000_000_000)
    }

    @Test func staleAvatarEnrichmentTaskCannotClearNewerTaskHandle() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let stale = UUID()
        let current = UUID()

        viewModel.installAvatarEnrichmentTaskForTesting(taskID: stale)
        viewModel.installAvatarEnrichmentTaskForTesting(taskID: current)
        viewModel.finishAvatarEnrichmentTaskForTesting(taskID: stale)

        #expect(viewModel.avatarEnrichmentTaskIDForTesting == current)

        viewModel.finishAvatarEnrichmentTaskForTesting(taskID: current)

        #expect(viewModel.avatarEnrichmentTaskIDForTesting == nil)
    }

    @Test func chatListRowUpdatesAreCoalescedBeforePublishing() async throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let older = chatListRow(
            groupIdHex: hex("e1"),
            title: "Older",
            lastMessage: chatListPreview(messageIdHex: hex("f1"), plaintext: "older", timelineAt: 10),
            updatedAt: 10
        )
        let newer = chatListRow(
            groupIdHex: hex("e2"),
            title: "Newer",
            lastMessage: chatListPreview(messageIdHex: hex("f2"), plaintext: "newer", timelineAt: 20),
            updatedAt: 20
        )

        viewModel.enqueueChatListRowUpdate(older)
        viewModel.enqueueChatListRowUpdate(newer)

        #expect(viewModel.items.isEmpty)
        try await waitForExpectation { viewModel.items.count == 2 }
        #expect(viewModel.items.map(\.id) == [newer.groupIdHex, older.groupIdHex])
    }

    @Test func directChatListRowUpdatesCanBeCoalescedBeforePublishing() async throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(
            groupIdHex: hex("e1"),
            title: "Read marker",
            lastMessage: chatListPreview(messageIdHex: hex("f1"), plaintext: "read", timelineAt: 10),
            updatedAt: 10
        )

        viewModel.enqueueChatListRowUpdate(row)

        #expect(viewModel.items.isEmpty)
        try await waitForExpectation { viewModel.items.map(\.id) == [row.groupIdHex] }
    }

    @Test func identicalProjectedRowDoesNotRepublishObservedLists() throws {
        let viewModel = ChatsListViewModel(appState: AppState.test())
        let row = chatListRow(
            groupIdHex: hex("e1"),
            title: "Stable",
            lastMessage: chatListPreview(messageIdHex: hex("f1"), plaintext: "stable", timelineAt: 10),
            updatedAt: 10
        )
        viewModel.applyChatListSnapshot([row])
        let mutationCount = viewModel.publishedItemsMutationCountForTesting

        viewModel.applyChatListRow(row)
        viewModel.applyChatListSnapshot([row])

        #expect(viewModel.publishedItemsMutationCountForTesting == mutationCount)
        #expect(viewModel.items.map(\.id) == [row.groupIdHex])
    }

}
