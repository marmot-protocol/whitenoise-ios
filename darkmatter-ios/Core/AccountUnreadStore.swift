import Foundation
import MarmotKit

/// Owns the per-account unread totals shown as badges on the account switcher.
/// A dumb mirror of Marmot's materialized chat-list aggregate, patched from
/// live active-list updates. Kept pure: index mutations take the current
/// `accounts` as a parameter, so the store needs no `AppState` back-reference —
/// AppState performs the Marmot fetch (its domain) and feeds the result here.
@MainActor
@Observable
final class AccountUnreadStore {
    /// Cached per-account unread totals keyed by account id hex.
    private(set) var byAccountId: [String: AccountUnreadFfi] = [:]

    func summary(forAccountIdHex accountIdHex: String) -> AccountUnreadFfi? {
        byAccountId[accountIdHex]
    }

    /// Replace the whole index from a fresh Marmot aggregate. Empty accounts
    /// clears it (nothing to attribute unread to).
    func refreshed(from summaries: [AccountUnreadFfi], accounts: [AccountSummaryFfi]) {
        guard !accounts.isEmpty else {
            byAccountId = [:]
            return
        }
        byAccountId = AccountUnreadSummaryProjection.byAccountId(summaries, accounts: accounts)
    }

    /// Patch one account's total from a live chat-list update; ignores ids that
    /// aren't currently known accounts.
    func update(accountIdHex: String, chatListRows: [ChatListRowFfi], accounts: [AccountSummaryFfi]) {
        guard accounts.contains(where: { $0.accountIdHex == accountIdHex }) else { return }
        byAccountId[accountIdHex] = AccountUnreadSummaryProjection.summary(
            accountIdHex: accountIdHex,
            rows: chatListRows
        )
    }

    /// Drop entries for accounts that no longer exist (used as the fallback when
    /// a refresh fetch fails, so stale signed-out totals don't linger).
    func pruneToCurrentAccounts(_ accounts: [AccountSummaryFfi]) {
        let knownAccountIds = Set(accounts.map(\.accountIdHex))
        byAccountId = byAccountId.filter { knownAccountIds.contains($0.key) }
    }
}
