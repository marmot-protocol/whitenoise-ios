import Foundation
import MarmotKit

/// Mirrors MDK's account-wide attention totals independently of loaded chat rows.
@MainActor
@Observable
final class AccountUnreadStore {
    /// Cached per-account unread totals keyed by account id hex.
    private(set) var byAccountId: [String: AccountUnreadFfi] = [:]
    private(set) var unavailableAccountIds: Set<String> = []
    private var incrementalRevision: UInt64 = 0
    private var incrementalRevisionByAccountId: [String: UInt64] = [:]

    func summary(forAccountIdHex accountIdHex: String) -> AccountUnreadFfi? {
        byAccountId[accountIdHex]
    }

    func badgeCount(forAccountIdHex accountIdHex: String) -> UInt64? {
        guard !unavailableAccountIds.contains(accountIdHex) else { return nil }
        guard let summary = byAccountId[accountIdHex] else { return nil }
        let count = ApplicationBadgeCountProjection.contribution(for: summary)
        return count > 0 ? count : nil
    }

    func applicationBadgeCount() -> Int? {
        // An unavailable account with no prior total must not clear the system badge.
        guard unavailableAccountIds.allSatisfy({ byAccountId[$0] != nil }) else { return nil }
        return ApplicationBadgeCountProjection.count(for: byAccountId.values)
    }

    /// Replace the whole index from a fresh Marmot aggregate. Empty accounts
    /// clears it (nothing to attribute unread to).
    func incrementalRevisionSnapshot() -> [String: UInt64] {
        incrementalRevisionByAccountId
    }

    func refreshed(
        from summaries: [AccountUnreadFfi],
        accounts: [AccountSummaryFfi],
        preservingUpdatesAfter baseline: [String: UInt64] = [:]
    ) {
        guard !accounts.isEmpty else {
            byAccountId = [:]
            unavailableAccountIds = []
            incrementalRevisionByAccountId = [:]
            return
        }
        var refreshed = AccountUnreadSummaryProjection.byAccountId(summaries, accounts: accounts)
        let knownAccountIds = Set(accounts.filter { !$0.signedOut }.map(\.accountIdHex))
        for account in accounts {
            let accountIdHex = account.accountIdHex
            let hasNewerLiveUpdate = incrementalRevisionByAccountId[accountIdHex, default: 0]
                > baseline[accountIdHex, default: 0]
            if hasNewerLiveUpdate {
                refreshed[accountIdHex] = byAccountId[accountIdHex]
            } else {
                unavailableAccountIds.remove(accountIdHex)
            }
        }
        byAccountId = refreshed
        unavailableAccountIds.formIntersection(knownAccountIds)
        incrementalRevisionByAccountId = incrementalRevisionByAccountId.filter {
            knownAccountIds.contains($0.key)
        }
    }

    func applyAttention(_ snapshot: AccountAttentionSnapshotFfi, accounts: [AccountSummaryFfi]) {
        let known = Set(accounts.filter { !$0.signedOut }.map(\.accountIdHex))
        let included = Set(snapshot.accounts.map(\.accountIdHex)).intersection(known)
        byAccountId = byAccountId.filter { included.contains($0.key) }
        unavailableAccountIds.formIntersection(included)
        incrementalRevisionByAccountId = incrementalRevisionByAccountId.filter { included.contains($0.key) }
        for entry in snapshot.accounts where known.contains(entry.accountIdHex) {
            // Even an unavailable update fences an older finite refresh.
            incrementalRevision &+= 1
            incrementalRevisionByAccountId[entry.accountIdHex] = incrementalRevision
            guard case .ready(let total) = entry.state else {
                unavailableAccountIds.insert(entry.accountIdHex)
                continue
            }
            unavailableAccountIds.remove(entry.accountIdHex)
            byAccountId[entry.accountIdHex] = AccountUnreadFfi(
                accountIdHex: entry.accountIdHex,
                unreadCount: total.unreadCount,
                unreadConversations: total.unreadConversations,
                attentionOnlyConversations: total.attentionOnlyConversations,
                hasUnread: total.unreadConversations > 0
            )
        }
    }

    /// Patch one account's total from a live chat-list update; ignores ids that
    /// aren't currently known accounts.
    func update(accountIdHex: String, chatListRows: [ChatListRowFfi], accounts: [AccountSummaryFfi]) {
        guard accounts.contains(where: { $0.accountIdHex == accountIdHex }) else { return }
        incrementalRevision &+= 1
        incrementalRevisionByAccountId[accountIdHex] = incrementalRevision
        byAccountId[accountIdHex] = AccountUnreadSummaryProjection.summary(
            accountIdHex: accountIdHex,
            rows: chatListRows
        )
    }

    /// Drop entries for accounts that no longer exist (used as the fallback when
    /// a refresh fetch fails, so stale signed-out totals don't linger).
    func pruneToCurrentAccounts(_ accounts: [AccountSummaryFfi]) {
        let knownAccountIds = Set(accounts.filter { !$0.signedOut }.map(\.accountIdHex))
        byAccountId = byAccountId.filter { knownAccountIds.contains($0.key) }
        unavailableAccountIds.formIntersection(knownAccountIds)
        incrementalRevisionByAccountId = incrementalRevisionByAccountId.filter {
            knownAccountIds.contains($0.key)
        }
    }
}
