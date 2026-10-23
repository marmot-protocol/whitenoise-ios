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
@Suite(.tags(.runtime))
struct PresentedChatListTests {
    @Test func expiringPreviewDisappearsWithoutAnMDKUpdate() async throws {
        let state = AppState.test()
        let model = ChatsListViewModel(appState: state)
        var preview = chatListPreview(messageIdHex: "expiring", plaintext: "Secret preview")
        preview.retentionSeconds = 60
        preview.retentionExpiresAt = UInt64(Date().timeIntervalSince1970) + 1
        let row = chatListRow(groupIdHex: "expiry", title: "Chat", lastMessage: preview)
        model.applyPresentedSnapshot(presentedChatSnapshot([row]))
        #expect(model.items.first?.searchHaystack.contains("secret preview") == true)
        for _ in 0..<400 where model.items.first?.previewExpired != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        let expired = try #require(model.items.first)
        #expect(expired.previewExpired)
        #expect(expired.lastMessage == nil)
        #expect(!expired.searchHaystack.contains("secret preview"))
        #expect(ChatRow.previewPresentation(for: expired, activeAccountIdHex: nil,
            senderName: { _ in "Sender" }).body == L10n.string("Message expired"))
    }

    @Test func pendingLeaveOverridesCachedPreparedLeaveAction() throws {
        let state = AppState.test()
        let model = ChatsListViewModel(appState: state)
        let row = chatListRow(groupIdHex: "pending-leave", title: "Chat")
        var snapshot = presentedChatSnapshot([row])
        snapshot.rows[0].actions = PresentedChatRowFfi.testActions(leave: true)
        model.applyPresentedSnapshot(snapshot)
        #expect(model.items.first?.departureAction == .leave)

        model.markGroupLeavePending(groupIdHex: row.groupIdHex)

        let pending = try #require(model.items.first)
        #expect(snapshot.rows[0].actions.canStartLeave)
        #expect(pending.actions?.canStartLeave == false)
        #expect(pending.departureStatus == .leaving)
        #expect(pending.departureAction == nil)
        #expect(!ChatListSwipeActionsPresentation.trailingActions(
            try #require(pending.actions), isMuted: false
        ).contains(.leave))

        snapshot.rows[0].row.selfMembership = .left
        snapshot.rows[0].row.leaveRequestPending = true
        snapshot.rows[0].actions = PresentedChatRowFfi.testActions(delete: true)
        model.applyPresentedSnapshot(snapshot)
        #expect(model.items.first?.departureAction == .deleteLocally)
    }

    @Test func preparedDraftChangesRefreshWithoutIdentityRevisionOrUnreadChanges() throws {
        let state = AppState.test()
        let model = ChatsListViewModel(appState: state)
        let row = chatListRow(groupIdHex: "draft", title: "Chat", lastMessage: chatListPreview(messageIdHex: "last"), unreadCount: 3)
        var snapshot = presentedChatSnapshot([row])
        model.applyPresentedSnapshot(snapshot)
        #expect(model.items.first?.draftPreview == nil)
        snapshot.rows[0].preview = .draft(draft: ChatListDraftPreviewFfi(
            text: "Unsent text", textTruncated: false, attachmentCount: 0, attachmentKind: nil))
        model.applyPresentedSnapshot(snapshot)
        let draft = try #require(model.items.first)
        #expect(draft.draftPreview == "Unsent text")
        #expect(draft.row == row)
        #expect(draft.searchHaystack.contains("unsent text"))
        #expect(ChatRow.previewPresentation(for: draft, activeAccountIdHex: nil, senderName: { _ in "Sender" }).body == L10n.formatted("Draft: %@", "Unsent text"))
        snapshot.rows[0].preview = .message
        snapshot.rows[0].actions = PresentedChatRowFfi.testActions(read: true, leave: true)
        model.applyPresentedSnapshot(snapshot)
        #expect(model.items.first?.draftPreview == nil)
        #expect(model.items.first?.actions?.canMarkRead == true)
        #expect(model.items.first?.departureAction == .leave)
        #expect(model.items.first?.unreadCount == 3)
    }

    @Test func invitationCanShowSelectedMessageWithoutLosingInviteState() throws {
        let state = AppState.test()
        let model = ChatsListViewModel(appState: state)
        let row = chatListRow(groupIdHex: "invite", pendingConfirmation: true, title: "Chat", lastMessage: chatListPreview(messageIdHex: "last", plaintext: "Invitation message"))
        model.applyPresentedSnapshot(presentedChatSnapshot([row]))
        let item = try #require(model.items.first)
        #expect(item.row.pendingConfirmation)
        #expect(ChatRow.previewPresentation(for: item, activeAccountIdHex: nil, senderName: { _ in "Sender" }).body == "Invitation message")
        var empty = presentedChatSnapshot([row])
        empty.rows[0].preview = .empty
        model.applyPresentedSnapshot(empty)
        let emptyItem = try #require(model.items.first)
        #expect(ChatRow.previewPresentation(for: emptyItem, activeAccountIdHex: nil, senderName: { _ in "Sender" }).body == L10n.string("No messages yet"))
    }

    @Test func avatarOnlySnapshotRefreshesPixelsWithoutChangingChatState() throws {
        let state = AppState.test()
        let model = ChatsListViewModel(appState: state)
        let row = chatListRow(groupIdHex: "avatar", title: "Selected")
        var snapshot = presentedChatSnapshot([row])
        model.applyPresentedSnapshot(snapshot)
        let original = try #require(model.items.first)
        snapshot.rows[0].avatarAsset = AvatarAssetFfi(target: "opaque-target", reference: "opaque-reference",
            availability: .ready, acquisition: nil, contentRevision: 2, byteCount: 40)
        model.applyPresentedSnapshot(snapshot)
        let refreshed = try #require(model.items.first)
        #expect(refreshed.avatarAsset?.contentRevision == 2)
        #expect(refreshed.row == original.row)
        #expect(refreshed.title == original.title)
        #expect(refreshed.unreadCount == original.unreadCount)
        #expect(refreshed.isPinned == original.isPinned)
        snapshot.rows[0].avatarAsset = nil
        model.applyPresentedSnapshot(snapshot)
        #expect(model.items.first?.avatarAsset == nil)
    }

    @Test func boundedReplacementEvictsRowsWithoutDroppingTheOpenDestinationOrChangingBadges() throws {
        let appState = AppState.test()
        let account = AccountSummaryFfi(label: "account", accountIdHex: "owner", localSigning: true, signedOut: false, running: true)
        appState.accountStore.accounts = [account]
        appState.applyAccountAttention(AccountAttentionSnapshotFfi(
            subscriptionGeneration: "attention", sequence: 0, accounts: [
                AccountAttentionEntryFfi(accountIdHex: "owner", state: .ready(total: AccountAttentionTotalFfi(
                    unreadCount: 500, unreadMentionCount: 0, unreadConversations: 5, attentionOnlyConversations: 1
                )))
            ]
        ))
        let model = ChatsListViewModel(appState: appState)
        func snapshot(_ range: Range<Int>, sequence: UInt64, generation: String = "window") -> ChatListWindowSnapshotFfi {
            ChatListWindowSnapshotFfi(
                subscriptionGeneration: generation, sequence: sequence, view: .chats,
                rows: presentedChatSnapshot(range.map { chatListRow(groupIdHex: String($0), title: "Chat \($0)") }).rows,
                hasMoreBefore: range.lowerBound > 0, hasMoreAfter: true,
                anchor: .retained(groupIdHex: String(range.lowerBound), index: 0)
            )
        }
        model.attachWindowForTesting(snapshot(0..<200, sequence: 0))
        model.retainDestination(groupIdHex: "0")
        model.receiveWindowForTesting(snapshot(50..<250, sequence: 1))
        #expect(model.items.count == 200)
        #expect(!model.items.contains { $0.id == "0" })
        #expect(model.item(groupIdHex: "0")?.title == "Chat 0")
        #expect(model.item(groupIdHex: "1") == nil)
        model.receiveWindowForTesting(snapshot(0..<50, sequence: 0))
        model.receiveWindowForTesting(snapshot(0..<50, sequence: 99, generation: "old-handle"))
        #expect(model.items.count == 200)
        #expect(appState.accountUnreadBadgeCount(forAccountIdHex: "owner") == 501)
        model.removeChatListRow(groupIdHex: "0")
        #expect(model.item(groupIdHex: "0") == nil)
    }

    @Test func snapshotTimingWaitsForDeferredPresentationAndRequiresConsent() async throws {
        let appState = AppState.test()
        let model = ChatsListViewModel(appState: appState)
        let snapshot = presentedChatSnapshot([chatListRow(groupIdHex: "timed", title: "Selected")])
        model.applyPresentedSnapshot(snapshot)
        let stages = Mutex<[ProductTimingStage]>([])
        appState.productAnalytics.activateSink(timing: { stage, _, _ in stages.withLock { $0.append(stage) } }) { _ in }
        let transition = model.beginPinOrderUITransition()
        model.applyPresentedSnapshot(snapshot)
        #expect(stages.withLock { $0.isEmpty })
        #expect(model.finishPinOrderUITransition(transitionID: transition, orderedGroupIds: nil))
        try await waitForExpectation { stages.withLock { $0.contains(.inboxSnapshot) } }
        #expect(stages.withLock { $0.filter { $0 == .inboxSnapshot }.count } == 1)
        appState.productAnalytics.replaceSink(nil)
    }

    @Test(.marmotRuntimeConcurrencyLimit) func createdChatResolvesBeforeAndAfterMissingPresentedRowRead() async throws {
        try await withTestClient { client in
            let appState = AppState.test(client: client)
            appState.setPhase(.ready)
            appState.setAppSceneActive(true)
            let model = ChatsListViewModel(appState: appState)
            await model.bind(accountRef: "account")
            let row = chatListRow(groupIdHex: "created", title: "Created chat")
            appState.noteCreatedChatListRow(accountRef: "account", row: row)
            model.presentedRowForTesting = { account, group in
                #expect(account == "account" && group == "created")
                #expect(model.item(groupIdHex: group)?.title == "Created chat")
                return nil
            }
            appState.presentChat(groupIdHex: row.groupIdHex)
            await model.refreshRow(groupIdHex: row.groupIdHex)
            #expect(model.item(groupIdHex: row.groupIdHex)?.title == "Created chat")
            model.presentedRowForTesting = nil
            await model.bind(accountRef: nil)
        }
    }

    @Test(.marmotRuntimeConcurrencyLimit, arguments: [false, true])
    func targetedReadSurvivesUnrelatedRowsButPreservesNewerTarget(targetChanges: Bool) async throws {
        try await withTestClient { client in
            let appState = AppState.test(client: client)
            appState.setPhase(.ready)
            appState.setAppSceneActive(true)
            let model = ChatsListViewModel(appState: appState)
            await model.bind(accountRef: "account")
            let selected = ConversationPresentationFfi(
                title: .literal(text: "Selected title"), avatar: .placeholder(stableSeed: "stable", source: .groupFallback),
                titleSource: .group, avatarSource: .groupFallback, peerId: nil, resolution: .lastKnown
            )
            let row = chatListRow(groupIdHex: "target", title: "Old title")
            model.presentedRowForTesting = { _, _ in
                model.applyChatListRow(chatListRow(groupIdHex: "unrelated", title: "Other chat"))
                if targetChanges { model.applyChatListRow(chatListRow(groupIdHex: "target", title: "Newer title")) }
                return PresentedChatRowFfi(row: row, presentation: selected, avatarAsset: nil)
            }
            await model.refreshRow(groupIdHex: row.groupIdHex)
            #expect(model.item(groupIdHex: row.groupIdHex)?.title == (targetChanges ? "Newer title" : "Selected title"))
            #expect(model.item(groupIdHex: "unrelated") != nil)
            model.presentedRowForTesting = nil
            await model.bind(accountRef: nil)
        }
    }

    @Test func selectedPresentationWinsOverLegacyFieldsAndPreservesUnreadChanges() throws {
        var row = chatListRow(groupIdHex: "presented", title: "Legacy title", avatarUrl: "https://legacy.example/avatar")
        let selected = ConversationPresentationFfi(
            title: .literal(text: "Selected title"),
            avatar: .placeholder(stableSeed: "stable", source: .groupFallback),
            titleSource: .group, avatarSource: .groupFallback, peerId: nil, resolution: .lastKnown
        )
        let appState = AppState.test()
        let model = ChatsListViewModel(appState: appState)
        let version = PresentationVersionFfi(accountStoreEpoch: Data([1]), revision: 1)
        model.applyPresentedSnapshot(PresentedChatListSnapshotFfi(
            rows: [PresentedChatRowFfi(row: row, presentation: selected, avatarAsset: nil)], presentationVersion: version
        ))
        #expect(model.items.first?.title == "Selected title")
        #expect(model.items.first?.avatarURL == nil)
        #expect(model.items.first?.avatarSeed == "stable")
        row.unreadCount = 4
        row.hasUnread = true
        model.applyPresentedSnapshot(PresentedChatListSnapshotFfi(
            rows: [PresentedChatRowFfi(row: row, presentation: selected, avatarAsset: nil)], presentationVersion: version
        ))
        #expect(model.items.first?.unreadCount == 4)
        model.applyPresentedSnapshot(PresentedChatListSnapshotFfi(rows: [], presentationVersion: version))
        #expect(model.items.isEmpty)
    }

    @Test(arguments: [false, true])
    func localNicknameOverridesSelectedDirectTitleAndRefreshesWithoutHydration(archived: Bool) async throws {
        let appState = AppState.test()
        let suite = "PresentedChatNicknames.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        appState.profileStore.contactNicknameDefaults = defaults
        let owner = String(repeating: "aa", count: 32)
        let secondOwner = String(repeating: "bb", count: 32)
        let peer = String(repeating: "cc", count: 32)
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "first", accountIdHex: owner, localSigning: true, signedOut: false, running: false),
            AccountSummaryFfi(label: "second", accountIdHex: secondOwner, localSigning: true, signedOut: false, running: false)
        ]
        appState.activeAccountRef = "first"
        appState.setContactNickname("Bestie", forAccountIdHex: peer)
        let model = ChatsListViewModel(appState: appState)
        let row = chatListRow(groupIdHex: "nickname-chat", archived: archived, title: "Legacy", conversationKind: .direct)
        let selected = ConversationPresentationFfi(
            title: .literal(text: "Public name"),
            avatar: .remoteImage(url: "https://example.com/selected.png", cacheKey: "selected-avatar"),
            titleSource: .peerProfile, avatarSource: .peerProfile, peerId: peer, resolution: .lastKnown
        )
        let snapshot = PresentedChatListSnapshotFfi(
            rows: [PresentedChatRowFfi(row: row, presentation: selected, avatarAsset: nil)],
            presentationVersion: PresentationVersionFfi(accountStoreEpoch: Data([1]), revision: 1)
        )
        model.applyPresentedSnapshot(snapshot)
        #expect((archived ? model.archivedItems : model.items).first?.title == "Bestie")
        #expect(model.item(groupIdHex: row.groupIdHex)?.selectedAvatar == selected.avatar)
        #expect(model.item(groupIdHex: row.groupIdHex)?.avatarSeed == peer)
        #expect(model.item(groupIdHex: row.groupIdHex)?.searchHaystack.contains("bestie") == true)
        let unchangedRevision = model.visibleRowsRevision
        model.refreshDisplayProjections()
        #expect(model.visibleRowsRevision == unchangedRevision)

        appState.setContactNickname("Buddy", forAccountIdHex: peer)
        model.refreshDisplayProjections()
        #expect(model.item(groupIdHex: row.groupIdHex)?.title == "Buddy")
        #expect(model.item(groupIdHex: row.groupIdHex)?.searchHaystack.contains("bestie") == false)
        model.applyPresentedSnapshot(snapshot)
        #expect(model.item(groupIdHex: row.groupIdHex)?.title == "Buddy")

        appState.activeAccountRef = "second"
        model.refreshDisplayProjections()
        #expect(model.item(groupIdHex: row.groupIdHex)?.title == "Public name")
        appState.activeAccountRef = "first"
        appState.setContactNickname(nil, forAccountIdHex: peer)
        model.refreshDisplayProjections()
        #expect(model.item(groupIdHex: row.groupIdHex)?.title == "Public name")
        #expect(appState.profileStore.queuedProfileProjectionLoadIDs.isEmpty)
        #expect(appState.profileStore.queuedProfileFetchIDs.isEmpty)
    }

    @Test func nicknameDoesNotReplaceGroupTitlesOrUnavailableConversation() {
        var row = chatListRow(groupIdHex: "group", title: "Legacy", conversationKind: .group)
        var selected = ConversationPresentationFfi(
            title: .literal(text: "Project room"), avatar: .placeholder(stableSeed: "group", source: .groupFallback),
            titleSource: .group, avatarSource: .groupFallback, peerId: "peer", resolution: .lastKnown
        )
        #expect(SelectedChatPresentation.display(selected, row: row, nickname: "Bestie").title == "Project room")
        row.conversationKind = .direct
        selected.title = .unavailableConversation
        #expect(SelectedChatPresentation.display(selected, row: row, nickname: "Bestie").title
            == L10n.string("Conversation unavailable"))
        selected.title = .literal(text: "Public name")
        selected.peerId = nil
        #expect(SelectedChatPresentation.display(selected, row: row, nickname: "Bestie").title == "Public name")
    }

    @Test func selectedAvatarRejectsPrivateURLsAndUsesLocalizableFallbacks() {
        let row = chatListRow(groupIdHex: "presented", title: "Legacy title")
        let selected = ConversationPresentationFfi(
            title: .unavailableConversation, avatar: .remoteImage(url: "https://127.0.0.1/private", cacheKey: "selected"),
            titleSource: .unknownFallback, avatarSource: .peerProfile, peerId: "peer", resolution: .fallback
        )
        let display = SelectedChatPresentation.display(selected, row: row)
        #expect(display.avatarURL == nil)
        #expect(display.title == L10n.string("Conversation unavailable"))
        #expect(display.avatarSeed == "peer")
    }
}
