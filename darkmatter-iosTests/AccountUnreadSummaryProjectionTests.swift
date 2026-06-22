import Testing
@testable import darkmatter_ios
@testable import MarmotKit

struct AccountUnreadSummaryProjectionTests {

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
                    hasUnread: true
                ),
                AccountUnreadFfi(
                    accountIdHex: "removed-account-id",
                    unreadCount: 9,
                    unreadConversations: 2,
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
        unreadCount: UInt64
    ) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: groupIdHex,
            archived: archived,
            pendingConfirmation: false,
            title: groupIdHex,
            groupName: groupIdHex,
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
            unreadCount: unreadCount,
            hasUnread: unreadCount > 0,
            firstUnreadMessageIdHex: unreadCount > 0 ? "message-\(groupIdHex)" : nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1
        )
    }
}
