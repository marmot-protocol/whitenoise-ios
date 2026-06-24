import Foundation
import MarmotKit

enum AccountUnreadSummaryProjection {
    static func byAccountId(
        _ summaries: [AccountUnreadFfi],
        accounts: [AccountSummaryFfi]
    ) -> [String: AccountUnreadFfi] {
        let knownAccountIds = Set(accounts.map(\.accountIdHex))
        var result: [String: AccountUnreadFfi] = [:]
        for summary in summaries where knownAccountIds.contains(summary.accountIdHex) {
            result[summary.accountIdHex] = summary
        }
        return result
    }

    static func summary<S: Sequence>(
        accountIdHex: String,
        rows: S
    ) -> AccountUnreadFfi where S.Element == ChatListRowFfi {
        var unreadCount: UInt64 = 0
        var unreadConversations: UInt64 = 0

        for row in rows where !row.archived && row.unreadCount > 0 {
            unreadCount = saturatedSum(unreadCount, row.unreadCount)
            if unreadConversations < UInt64.max {
                unreadConversations += 1
            }
        }

        return AccountUnreadFfi(
            accountIdHex: accountIdHex,
            unreadCount: unreadCount,
            unreadConversations: unreadConversations,
            hasUnread: unreadCount > 0
        )
    }

    private static func saturatedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
