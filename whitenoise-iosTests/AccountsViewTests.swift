import Testing
import Foundation
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
            attentionOnlyConversations: unreadCount == 0 && hasUnread ? 1 : 0,
            hasUnread: hasUnread
        )
    }

    @Test func showsBadgeWithAccountCountWhenUnread() {
        #expect(AccountsView.unreadBadgeCount(for: summary(unreadCount: 3, hasUnread: true)) == 3)
    }

    @Test func hidesBadgeWhenNothingUnread() {
        #expect(AccountsView.unreadBadgeCount(for: summary(unreadCount: 0, hasUnread: false)) == nil)
    }

    @Test func manualOnlyUnreadShowsAttentionInsteadOfZero() {
        #expect(AccountsView.unreadBadgeCount(for: summary(unreadCount: 0, hasUnread: true)) == 1)
    }

    @Test func hidesBadgeWhenNoSummaryYet() {
        #expect(AccountsView.unreadBadgeCount(for: nil) == nil)
    }

    @Test func shownCountRendersExpectedBadgeLabel() {
        let shown = AccountsView.unreadBadgeCount(for: summary(unreadCount: 250, hasUnread: true))
        #expect(shown == 250)
        #expect(shown.map {
            UnreadCountBadge.label(for: $0, locale: Locale(identifier: "en_US"))
        } == "99+")
    }

    @Test func compactSheetFitsOneOrTwoProfiles() {
        #expect(!AccountsView.prefersFullHeight(accountCount: 1))
        #expect(!AccountsView.prefersFullHeight(accountCount: 2))
    }

    @Test func fullHeightSheetClearsActionsForThreeOrMoreProfiles() {
        #expect(AccountsView.prefersFullHeight(accountCount: 3))
        #expect(AccountsView.prefersFullHeight(accountCount: 12))
    }

    @Test func activeProfileIsMarkedAheadOfEveryOtherState() {
        for signedOut in [true, false] {
            for localSigning in [true, false] {
                #expect(
                    AccountSummaryRow.Status.resolve(
                        isActive: true,
                        signedOut: signedOut,
                        localSigning: localSigning
                    ) == .active
                )
            }
        }
    }

    @Test func signedOutOutranksReadOnly() {
        #expect(
            AccountSummaryRow.Status.resolve(
                isActive: false,
                signedOut: true,
                localSigning: false
            ) == .signedOut
        )
    }

    @Test func missingLocalSigningReadsAsReadOnly() {
        #expect(
            AccountSummaryRow.Status.resolve(
                isActive: false,
                signedOut: false,
                localSigning: false
            ) == .readOnly
        )
    }

    @Test func signedInSigningProfileCarriesNoStatusMarker() {
        #expect(
            AccountSummaryRow.Status.resolve(
                isActive: false,
                signedOut: false,
                localSigning: true
            ) == .unmarked
        )
    }

    private func account(_ label: String, signedOut: Bool = false) -> AccountSummaryFfi {
        AccountSummaryFfi(
            label: label,
            accountIdHex: label,
            localSigning: true,
            signedOut: signedOut,
            running: !signedOut
        )
    }

    @Test func switcherHidesSignedOutProfiles() {
        let accounts = [account("a"), account("b", signedOut: true), account("c")]
        #expect(
            AccountsView.switcherAccounts(accounts, activeAccountRef: "a").map(\.label) == ["a", "c"]
        )
    }

    @Test func switcherListsActiveProfileFirst() {
        let accounts = [account("a"), account("b"), account("c")]
        #expect(
            AccountsView.switcherAccounts(accounts, activeAccountRef: "c").map(\.label) == ["c", "a", "b"]
        )
    }

    @Test func switcherKeepsOrderWithoutActiveProfile() {
        let accounts = [account("a", signedOut: true), account("b"), account("c")]
        #expect(
            AccountsView.switcherAccounts(accounts, activeAccountRef: nil).map(\.label) == ["b", "c"]
        )
    }
}
