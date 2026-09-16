import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct AccountUnreadSummaryProjectionTests {

    @MainActor
    @Test func staleFullRefreshPreservesIncrementalUpdateAfterItsBaseline() {
        let account = AccountSummaryFfi(
            label: "account-a",
            accountIdHex: "account-a-id",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let store = AccountUnreadStore()
        store.refreshed(
            from: [AccountUnreadFfi(
                accountIdHex: account.accountIdHex,
                unreadCount: 1,
                unreadConversations: 1,
                attentionOnlyConversations: 0,
                hasUnread: true
            )],
            accounts: [account]
        )
        let staleRefreshBaseline = store.incrementalRevisionSnapshot()

        store.update(
            accountIdHex: account.accountIdHex,
            chatListRows: [row(groupIdHex: "fresh", archived: false, unreadCount: 7)],
            accounts: [account]
        )
        store.refreshed(
            from: [AccountUnreadFfi(
                accountIdHex: account.accountIdHex,
                unreadCount: 2,
                unreadConversations: 1,
                attentionOnlyConversations: 0,
                hasUnread: true
            )],
            accounts: [account],
            preservingUpdatesAfter: staleRefreshBaseline
        )

        #expect(store.summary(forAccountIdHex: account.accountIdHex)?.unreadCount == 7)
    }

    @Test func summaryMatchesUnarchivedUnreadRows() {
        let summary = AccountUnreadSummaryProjection.summary(
            accountIdHex: "account-a",
            rows: [
                row(groupIdHex: "active-read", archived: false, unreadCount: 0),
                row(groupIdHex: "active-unread-a", archived: false, unreadCount: 2),
                row(groupIdHex: "active-unread-b", archived: false, unreadCount: 5),
                row(groupIdHex: "archived-unread", archived: true, unreadCount: 100),
            ]
        )

        #expect(summary.accountIdHex == "account-a")
        #expect(summary.unreadCount == 7)
        #expect(summary.unreadConversations == 2)
        #expect(summary.hasUnread)
    }

    @Test func summaryPreservesManualOnlyUnreadReminder() {
        let rows = [
            row(
                groupIdHex: "manual-reminder",
                archived: false,
                unreadCount: 0,
                manuallyMarkedUnread: true
            ),
        ]
        let summary = AccountUnreadSummaryProjection.summary(
            accountIdHex: "account-a",
            rows: rows
        )

        #expect(summary.unreadCount == 0)
        #expect(summary.unreadConversations == 1)
        #expect(summary.attentionOnlyConversations == 1)
        #expect(summary.hasUnread)
    }

    @Test func applicationBadgeAddsEverySupplementalConversationToMessageTotal() {
        let count = ApplicationBadgeCountProjection.count(for: [
            AccountUnreadFfi(
                accountIdHex: "account-a",
                unreadCount: 4,
                unreadConversations: 1,
                attentionOnlyConversations: 2,
                hasUnread: true
            ),
            AccountUnreadFfi(
                accountIdHex: "account-b",
                unreadCount: 0,
                unreadConversations: 1,
                attentionOnlyConversations: 1,
                hasUnread: true
            ),
            AccountUnreadFfi(
                accountIdHex: "account-c",
                unreadCount: 0,
                unreadConversations: 0,
                attentionOnlyConversations: 0,
                hasUnread: false
            ),
        ])

        #expect(count == 7)
    }

    @Test func aggregateOnlyManualUnreadStillContributesOne() {
        let count = ApplicationBadgeCountProjection.count(for: [
            AccountUnreadFfi(
                accountIdHex: "account-a",
                unreadCount: 0,
                unreadConversations: 1,
                attentionOnlyConversations: 1,
                hasUnread: true
            ),
        ])

        #expect(count == 1)
    }

    @Test func manualProjectionDoesNotDoubleCountChatsThatHaveUnreadMessages() {
        let rows = [
            row(
                groupIdHex: "manual-only",
                archived: false,
                unreadCount: 0,
                manuallyMarkedUnread: true
            ),
            row(
                groupIdHex: "already-unread",
                archived: false,
                unreadCount: 3,
                manuallyMarkedUnread: true
            ),
            row(
                groupIdHex: "archived-manual",
                archived: true,
                unreadCount: 0,
                manuallyMarkedUnread: true
            ),
        ]

        let summary = AccountUnreadSummaryProjection.summary(
            accountIdHex: "account-a",
            rows: rows
        )
        #expect(summary.attentionOnlyConversations == 1)
    }

    @Test func pendingInvitesNeverContributeToUnreadBadges() {
        let rows = [
            row(
                groupIdHex: "pending-invite",
                archived: false,
                unreadCount: 0,
                pendingConfirmation: true
            ),
            row(
                groupIdHex: "invite-with-unread-message",
                archived: false,
                unreadCount: 2,
                pendingConfirmation: true
            ),
            row(
                groupIdHex: "archived-invite",
                archived: true,
                unreadCount: 0,
                pendingConfirmation: true
            ),
        ]

        let summary = AccountUnreadSummaryProjection.summary(
            accountIdHex: "account-a",
            rows: rows
        )
        #expect(summary.unreadCount == 0)
        #expect(summary.attentionOnlyConversations == 0)
        #expect(ApplicationBadgeCountProjection.contribution(for: summary) == 0)
    }

    @MainActor
    @Test func storeKeepsAttentionOnlyContributionAcrossDurableSummaryRefresh() {
        let account = AccountSummaryFfi(
            label: "account-a",
            accountIdHex: "account-a-id",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let store = AccountUnreadStore()
        store.update(
            accountIdHex: account.accountIdHex,
            chatListRows: [
                row(groupIdHex: "message", archived: false, unreadCount: 4),
                row(
                    groupIdHex: "manual",
                    archived: false,
                    unreadCount: 0,
                    manuallyMarkedUnread: true
                ),
            ],
            accounts: [account]
        )

        #expect(store.badgeCount(forAccountIdHex: account.accountIdHex) == 5)
        let refreshBaseline = store.incrementalRevisionSnapshot()

        store.refreshed(
            from: [
                AccountUnreadFfi(
                    accountIdHex: account.accountIdHex,
                    unreadCount: 6,
                    unreadConversations: 2,
                    attentionOnlyConversations: 1,
                    hasUnread: true
                ),
            ],
            accounts: [account],
            preservingUpdatesAfter: refreshBaseline
        )

        #expect(store.badgeCount(forAccountIdHex: account.accountIdHex) == 7)
    }

    @Test func applicationBadgeSaturatesAtPlatformIntegerMaximum() {
        let count = ApplicationBadgeCountProjection.count(for: [
            AccountUnreadFfi(
                accountIdHex: "account-a",
                unreadCount: .max,
                unreadConversations: 1,
                attentionOnlyConversations: 0,
                hasUnread: true
            ),
            AccountUnreadFfi(
                accountIdHex: "account-b",
                unreadCount: 1,
                unreadConversations: 1,
                attentionOnlyConversations: 0,
                hasUnread: true
            ),
        ])

        #expect(count == Int.max)
    }

    @Test func byAccountIdDropsSummariesForUnknownAccounts() {
        let account = AccountSummaryFfi(
            label: "account-a",
            accountIdHex: "account-a-id",
            localSigning: true,
            signedOut: false,
            running: true
        )

        let result = AccountUnreadSummaryProjection.byAccountId(
            [
                AccountUnreadFfi(
                    accountIdHex: "account-a-id",
                    unreadCount: 3,
                    unreadConversations: 1,
                    attentionOnlyConversations: 0,
                    hasUnread: true
                ),
                AccountUnreadFfi(
                    accountIdHex: "removed-account-id",
                    unreadCount: 9,
                    unreadConversations: 2,
                    attentionOnlyConversations: 0,
                    hasUnread: true
                ),
            ],
            accounts: [account]
        )

        #expect(Set(result.keys) == Set(["account-a-id"]))
        #expect(result["account-a-id"]?.unreadCount == 3)
    }

    private func row(
        groupIdHex: String,
        archived: Bool,
        unreadCount: UInt64,
        manuallyMarkedUnread: Bool = false,
        pendingConfirmation: Bool = false
    ) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            title: groupIdHex,
            groupName: groupIdHex,
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
            unreadCount: unreadCount,
            hasUnread: unreadCount > 0 || manuallyMarkedUnread,
            manuallyMarkedUnread: manuallyMarkedUnread,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: unreadCount > 0 ? "message-\(groupIdHex)" : nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            conversationCreatedAt: 1,
            activitySortAt: 1,
            updatedAt: 1,
            selfMembership: .member,
            conversationKind: .group,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: false,
            leaveRequestedAtMs: nil
        )
    }
}
