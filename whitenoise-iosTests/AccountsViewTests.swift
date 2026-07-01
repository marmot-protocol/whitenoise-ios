import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// The Profiles rows show an unread badge per account. These lock the row's
/// decision — shown only when the account has unread, with the account's count
/// — and that the count renders the expected badge label.
@MainActor
struct AccountsViewTests {

    private func summary(unreadCount: UInt64, hasUnread: Bool) -> AccountUnreadFfi {
        AccountUnreadFfi(
            accountIdHex: "account-a",
            unreadCount: unreadCount,
            unreadConversations: unreadCount > 0 ? 1 : 0,
            hasUnread: hasUnread
        )
    }

    @Test func showsBadgeWithAccountCountWhenUnread() {
        #expect(AccountsView.unreadBadgeCount(for: summary(unreadCount: 3, hasUnread: true)) == 3)
    }

    @Test func hidesBadgeWhenNothingUnread() {
        #expect(AccountsView.unreadBadgeCount(for: summary(unreadCount: 0, hasUnread: false)) == nil)
    }

    @Test func hidesBadgeWhenNoSummaryYet() {
        #expect(AccountsView.unreadBadgeCount(for: nil) == nil)
    }

    @Test func shownCountRendersExpectedBadgeLabel() {
        let shown = AccountsView.unreadBadgeCount(for: summary(unreadCount: 250, hasUnread: true))
        #expect(shown == 250)
        #expect(shown.map { UnreadCountBadge.label(for: $0) } == "99+")
    }
}
