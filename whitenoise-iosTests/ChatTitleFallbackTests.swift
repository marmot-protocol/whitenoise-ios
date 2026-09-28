import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct ChatTitleFallbackGraceTests {
    @Test func fallbackTitleStaysPendingForThreeSecondsFromFirstSighting() {
        var grace = ChatTitleFallbackGrace()
        let start = ContinuousClock.now

        let first = grace.isPending(groupIdHex: "g", isFallback: true, now: start)
        let almost = grace.isPending(groupIdHex: "g", isFallback: true, now: start + .milliseconds(2_999))
        let expired = grace.isPending(groupIdHex: "g", isFallback: true, now: start + .seconds(3))
        let later = grace.isPending(groupIdHex: "g", isFallback: true, now: start + .seconds(10))

        #expect(first)
        #expect(almost)
        #expect(!expired)
        #expect(!later)
    }

    @Test func resolvedTitleIsNeverPendingAndRestartsTheGraceOnFallbackAgain() {
        var grace = ChatTitleFallbackGrace()
        let start = ContinuousClock.now

        let fallback = grace.isPending(groupIdHex: "g", isFallback: true, now: start)
        let resolved = grace.isPending(groupIdHex: "g", isFallback: false, now: start + .seconds(1))
        let deadlineAfterResolve = grace.nextDeadline(after: start + .seconds(1))
        let fallbackAgain = grace.isPending(groupIdHex: "g", isFallback: true, now: start + .seconds(5))

        #expect(fallback)
        #expect(!resolved)
        #expect(deadlineAfterResolve == nil)
        #expect(fallbackAgain)
    }

    @Test func nextDeadlineIsTheEarliestUnexpiredGraceEnd() {
        var grace = ChatTitleFallbackGrace()
        let start = ContinuousClock.now
        _ = grace.isPending(groupIdHex: "a", isFallback: true, now: start)
        _ = grace.isPending(groupIdHex: "b", isFallback: true, now: start + .seconds(1))

        #expect(grace.nextDeadline(after: start) == start + .seconds(3))
        #expect(grace.nextDeadline(after: start + .seconds(3)) == start + .seconds(4))
        #expect(grace.nextDeadline(after: start + .seconds(4)) == nil)

        grace.reset()
        #expect(grace.nextDeadline(after: start) == nil)
    }
}

@MainActor
struct ChatTitleFallbackPresentationTests {
    private let peer = String(repeating: "ab", count: 32)

    @Test func peerFallbackTitleShowsUnknownUserInsteadOfTheMadeUpName() {
        let display = SelectedChatPresentation.display(
            presentation(title: "Brave Otter", source: .peerFallback),
            row: row(kind: .direct)
        )
        #expect(display.title == L10n.string("Unknown user"))
        #expect(display.isTitleFallback)
    }

    @Test func peerProfileTitleIsShownAsIs() {
        let display = SelectedChatPresentation.display(
            presentation(title: "Alice", source: .peerProfile),
            row: row(kind: .direct)
        )
        #expect(display.title == "Alice")
        #expect(!display.isTitleFallback)
    }

    @Test func localNicknameWinsOverTheFallbackWithoutAPlaceholder() {
        let display = SelectedChatPresentation.display(
            presentation(title: "Brave Otter", source: .peerFallback),
            row: row(kind: .direct),
            nickname: "Bestie"
        )
        #expect(display.title == "Bestie")
        #expect(!display.isTitleFallback)
    }

    @Test func chatListShowsAPlaceholderUntilTheRealNameArrives() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        let model = ChatsListViewModel(appState: appState)
        let chatRow = row(kind: .direct)

        model.applyPresentedSnapshot(snapshot(chatRow, presentation(title: "Brave Otter", source: .peerFallback), revision: 1))
        let pending = try #require(model.item(groupIdHex: chatRow.groupIdHex))
        #expect(pending.isTitlePending)
        #expect(pending.title == L10n.string("Unknown user"))
        #expect(!pending.searchHaystack.localizedStandardContains("otter"))

        model.applyPresentedSnapshot(snapshot(chatRow, presentation(title: "Alice", source: .peerProfile), revision: 2))
        let resolved = try #require(model.item(groupIdHex: chatRow.groupIdHex))
        #expect(!resolved.isTitlePending)
        #expect(resolved.title == "Alice")
    }

    private func presentation(title: String, source: PresentationSourceFfi) -> ConversationPresentationFfi {
        ConversationPresentationFfi(
            title: .literal(text: title),
            avatar: .placeholder(stableSeed: "seed", source: source),
            titleSource: source, avatarSource: source, peerId: peer, resolution: .lastKnown
        )
    }

    private func snapshot(
        _ row: ChatListRowFfi,
        _ selected: ConversationPresentationFfi,
        revision: UInt64
    ) -> PresentedChatListSnapshotFfi {
        PresentedChatListSnapshotFfi(
            rows: [PresentedChatRowFfi(row: row, presentation: selected, avatarAsset: nil)],
            presentationVersion: PresentationVersionFfi(accountStoreEpoch: Data([1]), revision: revision)
        )
    }

    private func row(kind: ChatConversationKindFfi) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: "fallback-chat", pinned: false, pinnedPosition: nil, archived: false,
            pendingConfirmation: false, title: "", groupName: "", avatarUrl: nil, avatar: nil,
            lastMessage: nil, unreadCount: 0, hasUnread: false, manuallyMarkedUnread: false,
            unreadMentionCount: 0, unreadMention: false, firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil, lastReadTimelineAt: nil, conversationCreatedAt: 1,
            activitySortAt: 1, updatedAt: 1, selfMembership: .member, conversationKind: kind,
            muted: false, mutedUntilMs: nil, leaveRequestPending: false, leaveRequestedAtMs: nil
        )
    }
}
