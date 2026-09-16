import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct AccountAttentionTests {
    @Test func unavailableRetainsLastKnownButOmittedAndSignedOutAccountsDisappear() {
        let accounts = [account("a"), account("b")]
        let store = AccountUnreadStore()
        store.applyAttention(snapshot([
            entry("a", .ready(total: total(9, reminders: 1))),
            entry("b", .ready(total: total(3))),
        ]), accounts: accounts)
        #expect(store.applicationBadgeCount() == 13)
        store.applyAttention(snapshot([
            entry("a", .unavailable(reason: .readFailed)),
            entry("b", .unavailable(reason: .resetting)),
        ]), accounts: accounts)
        #expect(store.applicationBadgeCount() == 13)
        #expect(store.unavailableAccountIds == ["a", "b"])
        #expect(store.badgeCount(forAccountIdHex: "a") == nil)
        store.applyAttention(snapshot([entry("a", .unavailable(reason: .preparing))]), accounts: accounts)
        #expect(store.applicationBadgeCount() == 10)
        store.applyAttention(snapshot([entry("a", .ready(total: total(99)))]), accounts: [account("a", signedOut: true)])
        #expect(store.applicationBadgeCount() == 0)
        #expect(store.unavailableAccountIds.isEmpty)
    }

    @Test func unavailableWithoutPriorTotalDoesNotInventZero() {
        let store = AccountUnreadStore()
        store.applyAttention(snapshot([entry("a", .unavailable(reason: .preparing))]), accounts: [account("a")])
        #expect(store.summary(forAccountIdHex: "a") == nil)
        #expect(store.unavailableAccountIds.contains("a"))
        #expect(store.applicationBadgeCount() == nil)
        store.applyAttention(snapshot([entry("a", .ready(total: total(0)))]), accounts: [account("a")])
        #expect(store.summary(forAccountIdHex: "a")?.unreadCount == 0)
        #expect(store.applicationBadgeCount() == 0)
        #expect(store.unavailableAccountIds.isEmpty)
    }

    @Test func unavailableFencesFiniteRefreshEvenWithoutCachedTotal() {
        let store = AccountUnreadStore()
        let accounts = [account("a")]
        let baseline = store.incrementalRevisionSnapshot()
        store.applyAttention(snapshot([entry("a", .unavailable(reason: .readFailed))]), accounts: accounts)
        store.refreshed(from: [AccountUnreadFfi(
            accountIdHex: "a", unreadCount: 7, unreadConversations: 1,
            attentionOnlyConversations: 0, hasUnread: true
        )], accounts: accounts, preservingUpdatesAfter: baseline)
        #expect(store.summary(forAccountIdHex: "a") == nil)
        #expect(store.unavailableAccountIds.contains("a"))
    }

    @Test func pendingInvitationAttentionIsCountedOnce() {
        let store = AccountUnreadStore()
        store.applyAttention(snapshot([entry("a", .ready(total: total(4, reminders: 2)))]), accounts: [account("a")])
        #expect(store.applicationBadgeCount() == 6)
        #expect(store.badgeCount(forAccountIdHex: "a") == 6)
    }

    @Test func duplicateCommandReplyAndOldHandleUpdatesCannotRegressSequence() {
        var cursor = ProjectionSequenceCursor(generation: "current", sequence: 4)
        let newer = cursor.accept(generation: "current", sequence: 6)
        let duplicate = cursor.accept(generation: "current", sequence: 6)
        let older = cursor.accept(generation: "current", sequence: 5)
        let replaced = cursor.accept(generation: "replaced", sequence: 100)
        #expect(newer && !duplicate && !older && !replaced)
        #expect(cursor.sequence == 6)
    }

    private func account(_ id: String, signedOut: Bool = false) -> AccountSummaryFfi {
        AccountSummaryFfi(label: id, accountIdHex: id, localSigning: true, signedOut: signedOut, running: false)
    }
    private func total(_ unread: UInt64, reminders: UInt64 = 0) -> AccountAttentionTotalFfi {
        AccountAttentionTotalFfi(unreadCount: unread, unreadMentionCount: 0,
            unreadConversations: (unread > 0 ? 1 : 0) + reminders, attentionOnlyConversations: reminders)
    }
    private func entry(_ id: String, _ state: AccountAttentionStateFfi) -> AccountAttentionEntryFfi {
        AccountAttentionEntryFfi(accountIdHex: id, state: state)
    }
    private func snapshot(_ entries: [AccountAttentionEntryFfi]) -> AccountAttentionSnapshotFfi {
        AccountAttentionSnapshotFfi(subscriptionGeneration: "test", sequence: 0, accounts: entries)
    }
}
