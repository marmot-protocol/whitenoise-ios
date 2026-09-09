import Testing
@testable import whitenoise_ios

/// A chat row shows one marker at its trailing edge. An unanswered invitation
/// is the whole story of that row, so it replaces the unread marker instead of
/// stacking with it.
struct ChatRowStatusPresentationTests {
    @Test func pendingInvitationShowsTheInviteBadge() {
        #expect(
            ChatRowStatusPresentation.status(
                isInvitationPending: true,
                hasUnread: false,
                unreadCount: 0
            ) == .invitation
        )
    }

    @Test func pendingInvitationSuppressesTheUnreadBadge() {
        #expect(
            ChatRowStatusPresentation.status(
                isInvitationPending: true,
                hasUnread: true,
                unreadCount: 7
            ) == .invitation
        )
    }

    @Test func answeredRowsFallBackToTheUnreadCount() {
        #expect(
            ChatRowStatusPresentation.status(
                isInvitationPending: false,
                hasUnread: true,
                unreadCount: 7
            ) == .unread(7)
        )
    }

    /// A row marked unread by hand carries no count; `UnreadCountBadge` turns
    /// the zero into a dot, so the count must survive as zero rather than
    /// collapsing to no status at all.
    @Test func manuallyUnreadRowsKeepAZeroCount() {
        #expect(
            ChatRowStatusPresentation.status(
                isInvitationPending: false,
                hasUnread: true,
                unreadCount: 0
            ) == .unread(0)
        )
    }

    @Test func readRowsShowNothing() {
        #expect(
            ChatRowStatusPresentation.status(
                isInvitationPending: false,
                hasUnread: false,
                unreadCount: 0
            ) == .none
        )
    }

    /// A stale count on an already-read row must not resurrect the badge.
    @Test func readRowsIgnoreALeftoverCount() {
        #expect(
            ChatRowStatusPresentation.status(
                isInvitationPending: false,
                hasUnread: false,
                unreadCount: 7
            ) == .none
        )
    }
}
