import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct NotificationServiceProjectionTests {

    @Test func newDataCollectionUsesNewestPresentableNotification() {
        let older = notificationUpdate(
            notificationKey: "older",
            senderName: "Alice",
            previewText: "first",
            timestampMs: 1_000
        )
        let newer = notificationUpdate(
            notificationKey: "newer",
            senderName: "Bob",
            previewText: "second",
            timestampMs: 2_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [older, newer],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: newer)!,
            additionalPresentations: [
                LocalNotificationProjection.makePresentation(for: older)!
            ]
        ))
    }

    @Test func newDataCollectionCarriesRemainingPresentationsForSameWake() {
        let older = notificationUpdate(
            notificationKey: "older",
            senderName: "Alice",
            previewText: "first",
            timestampMs: 1_000
        )
        let newer = notificationUpdate(
            notificationKey: "newer",
            senderName: "Bob",
            previewText: "second",
            timestampMs: 2_000
        )
        let selfMessage = notificationUpdate(
            notificationKey: "self",
            isFromSelf: true,
            timestampMs: 3_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [older, selfMessage, newer],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: newer)!,
            additionalPresentations: [
                LocalNotificationProjection.makePresentation(for: older)!
            ]
        ))
    }

    @Test func newDataCollectionShowsAllAdditionalPresentationsAtTheCap() {
        // primary + exactly maxAdditionalPresentations additional => no overflow,
        // every record shown individually, no summary appended.
        let total = NotificationServiceProjection.maxAdditionalPresentations + 1
        let updates = (0..<total).map { index in
            notificationUpdate(
                notificationKey: "notif-\(index)",
                previewText: "message-\(index)",
                // newest first after sort: higher timestamp == newer
                timestampMs: Int64(10_000 - index)
            )
        }
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: updates.shuffled(),
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        let expectedPresentations = updates.map {
            LocalNotificationProjection.makePresentation(for: $0)!
        }
        #expect(decision == .decorate(
            expectedPresentations.first!,
            additionalPresentations: Array(expectedPresentations.dropFirst())
        ))
    }

    @Test func newDataCollectionShowsSingleRecordOverCapWithoutSummary() {
        let total = NotificationServiceProjection.maxAdditionalPresentations + 2
        let updates = (0..<total).map { index in
            notificationUpdate(
                notificationKey: "notif-\(index)",
                previewText: "message-\(index)",
                timestampMs: Int64(10_000 - index)
            )
        }
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: updates.shuffled(),
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        let expectedPresentations = updates.map {
            LocalNotificationProjection.makePresentation(for: $0)!
        }
        #expect(decision == .decorate(
            expectedPresentations.first!,
            additionalPresentations: Array(expectedPresentations.dropFirst())
        ))
    }

    @Test func newDataCollectionCapsAdditionalPresentationsAndCoalescesOverflow() {
        let cap = NotificationServiceProjection.maxAdditionalPresentations
        let overflow = 5
        // primary + cap shown individually + overflow folded into one summary.
        let total = 1 + cap + overflow
        let updates = (0..<total).map { index in
            notificationUpdate(
                notificationKey: "notif-\(index)",
                previewText: "message-\(index)",
                timestampMs: Int64(100_000 - index)
            )
        }
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: updates.shuffled(),
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        guard case let .decorate(primary, additional) = decision else {
            Issue.record("expected decorate decision, got \(decision)")
            return
        }

        // Exactly cap individually-shown additional presentations + 1 summary.
        #expect(additional.count == cap + 1)

        let presentations = updates.map {
            LocalNotificationProjection.makePresentation(for: $0)!
        }
        #expect(primary == presentations.first!)
        // The first `cap` additional presentations are the next-newest records,
        // shown individually.
        #expect(Array(additional.prefix(cap)) == Array(presentations.dropFirst().prefix(cap)))

        // The trailing entry is a coalesced summary, not an abandoned record.
        let summary = additional.last!
        #expect(summary.title == L10n.string("White Noise"))
        #expect(summary.body == L10n.plural("%lld more messages", Int64(overflow)))
        // Summary carries no message content/preview from the overflow records.
        for index in (1 + cap)..<total {
            #expect(!summary.body.contains("message-\(index)"))
        }
        // Distinct identifier so the summary never dedupes against a real message.
        #expect(summary.identifier != primary.identifier)
        for shown in additional.dropLast() {
            #expect(summary.identifier != shown.identifier)
        }
        // Routes to the newest conversation so a tap lands somewhere sane.
        #expect(summary.threadIdentifier == primary.threadIdentifier)
        #expect(summary.route.accountRef == primary.route.accountRef)
        #expect(summary.route.groupIdHex == primary.route.groupIdHex)
        #expect(summary.route.messageIdHex == nil)
    }

    @Test func overflowSummariesStayOnTheirOwnNotificationRoutes() {
        let cap = NotificationServiceProjection.maxAdditionalPresentations
        let primary = notificationUpdate(
            notificationKey: "primary",
            accountRef: "account-a",
            groupIdHex: "group-a",
            timestampMs: 100_000
        )
        let shown = (0..<cap).map { index in
            notificationUpdate(
                notificationKey: "shown-\(index)",
                accountRef: "account-a",
                groupIdHex: "group-a",
                timestampMs: Int64(90_000 - index)
            )
        }
        let overflow = [
            notificationUpdate(
                notificationKey: "overflow-b-1",
                conversationKey: "conv-b",
                accountRef: "account-b",
                groupIdHex: "group-b",
                timestampMs: 80_000
            ),
            notificationUpdate(
                notificationKey: "overflow-b-2",
                conversationKey: "conv-b",
                accountRef: "account-b",
                groupIdHex: "group-b",
                timestampMs: 79_000
            ),
            notificationUpdate(
                notificationKey: "overflow-c-1",
                conversationKey: "conv-c",
                accountRef: "account-c",
                groupIdHex: "group-c",
                timestampMs: 78_000
            )
        ]
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: ([primary] + shown + overflow).shuffled(),
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        guard case let .decorate(_, additional) = decision else {
            Issue.record("expected decorate decision, got \(decision)")
            return
        }

        let summaries = Array(additional.dropFirst(cap))
        #expect(summaries.map(\.route.accountRef) == ["account-b", "account-c"])
        #expect(summaries.map(\.route.groupIdHex) == ["group-b", "group-c"])
        #expect(summaries.map(\.threadIdentifier) == ["conv-b", "conv-c"])
        #expect(summaries.map(\.body) == [
            L10n.plural("%lld more messages", Int64(2)),
            L10n.plural("%lld more messages", Int64(1))
        ])
    }

    @Test func boundedAdditionalPresentationsCoalescesOverflowWithoutDroppingRecords() {
        // Unit-level coverage of the live NSE bounding path (the one
        // `decision(...)` uses).
        let cap = NotificationServiceProjection.maxAdditionalPresentations
        let additionalUpdates = (0..<(cap + 3)).map { index in
            notificationUpdate(notificationKey: "add-\(index)", timestampMs: Int64(900 - index))
        }

        let bounded = NotificationPresentationPolicy.boundedAdditionalPresentations(
            from: additionalUpdates
        )

        // cap shown + a single summary; the 3 overflow records are represented, not lost.
        let shown = additionalUpdates.prefix(cap).compactMap {
            LocalNotificationProjection.makePresentation(for: $0)
        }
        #expect(bounded.count == cap + 1)
        #expect(Array(bounded.prefix(cap)) == shown)
        #expect(bounded.last!.body == L10n.plural("%lld more messages", Int64(3)))
    }

    @Test func boundedAdditionalPresentationsLeavesSmallListUntouched() {
        let additionalUpdates = (0..<3).map { index in
            notificationUpdate(notificationKey: "add-\(index)", timestampMs: Int64(900 - index))
        }

        let bounded = NotificationPresentationPolicy.boundedAdditionalPresentations(
            from: additionalUpdates
        )

        #expect(bounded == additionalUpdates.compactMap {
            LocalNotificationProjection.makePresentation(for: $0)
        })
    }

    @Test func equalTimestampsUseStableOrdering() {
        let updates = [
            notificationUpdate(
                notificationKey: "key-b",
                accountRef: "account-b",
                groupIdHex: "group-a",
                timestampMs: 2_000
            ),
            notificationUpdate(
                notificationKey: "key-a",
                accountRef: "account-a",
                groupIdHex: "group-z",
                timestampMs: 2_000
            ),
            notificationUpdate(
                notificationKey: "key-c",
                accountRef: "account-b",
                groupIdHex: "group-b",
                timestampMs: 2_000
            )
        ]
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: updates,
            error: nil
        )

        let decision = NotificationServiceProjection.decision(for: collection)

        guard case let .decorate(primary, additional) = decision else {
            Issue.record("expected decorate decision, got \(decision)")
            return
        }
        #expect(primary.identifier == "key-a")
        #expect(additional.map(\.identifier) == ["key-b", "key-c"])
    }

    @Test func disabledLocalNotificationsDeliverQuietlyFromTheNSE() {
        // Disabling local notifications must not produce an audible generic
        // banner per message; the wake sheds its alert and lands quietly,
        // matching the all-muted wake. Forward-looking: the pinned engine
        // currently discards disabled-account records at ingest (the wake
        // arrives as an empty `.noData` collection instead), so this state
        // only occurs once the engine surfaces suppressed records.
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [
                notificationUpdate(accountRef: "disabled-account")
            ],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            localNotificationsEnabled: { _ in false }
        )

        #expect(decision == .deliverQuietly)
    }

    @Test func archivedNotificationsAreFilteredBeforeChoosingPresentation() {
        let archivedNewer = notificationUpdate(
            notificationKey: "archived-newer",
            accountRef: "account-a",
            groupIdHex: "group-archived",
            timestampMs: 3_000
        )
        let visibleOlder = notificationUpdate(
            notificationKey: "visible-older",
            accountRef: "account-a",
            groupIdHex: "group-visible",
            timestampMs: 2_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [archivedNewer, visibleOlder],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            isArchived: { _, groupIdHex in groupIdHex == "group-archived" }
        )

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: visibleOlder)!,
            additionalPresentations: []
        ))
    }

    @Test func disabledLocalNotificationsAreFilteredBeforeChoosingNewestPresentation() {
        let disabledNewer = notificationUpdate(
            notificationKey: "disabled-newer",
            accountRef: "account-disabled",
            senderName: "Muted",
            previewText: "private",
            timestampMs: 3_000
        )
        let enabledMiddle = notificationUpdate(
            notificationKey: "enabled-middle",
            accountRef: "account-enabled",
            senderName: "Visible",
            previewText: "shown",
            timestampMs: 2_000
        )
        let enabledOlder = notificationUpdate(
            notificationKey: "enabled-older",
            accountRef: "account-enabled",
            senderName: "Also visible",
            previewText: "also shown",
            timestampMs: 1_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [enabledOlder, disabledNewer, enabledMiddle],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            localNotificationsEnabled: { $0 == "account-enabled" }
        )

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: enabledMiddle)!,
            additionalPresentations: [
                LocalNotificationProjection.makePresentation(for: enabledOlder)!
            ]
        ))
    }

    @Test func memoizingReadResolvesEachDistinctAccountAtMostOncePerWake() {
        // A backlog of many records spanning only a couple of distinct accounts
        // must not issue one settings read per record (the NSE's read is a
        // synchronous FFI call inside the ~8 s wake budget). Wrapping the read
        // with the memoizing policy should resolve each distinct accountRef once.
        var readCounts: [String: Int] = [:]
        let memoized = NotificationServiceSettingsReadPolicy.memoizingLocalNotificationsEnabled { accountRef in
            readCounts[accountRef, default: 0] += 1
            return accountRef == "account-enabled"
        }

        let notifications = (0..<40).map { index -> NotificationUpdateFfi in
            // Alternate between two accounts so distinct count is 2, records 40.
            let accountRef = index.isMultiple(of: 2) ? "account-enabled" : "account-disabled"
            return notificationUpdate(
                notificationKey: "notif-\(index)",
                accountRef: accountRef,
                timestampMs: Int64(10_000 - index)
            )
        }
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: notifications,
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            localNotificationsEnabled: memoized
        )

        // Each distinct account is read exactly once despite 40 records.
        #expect(readCounts == ["account-enabled": 1, "account-disabled": 1])

        // Memoization must not change the filtering outcome: only enabled-account
        // records survive, newest first.
        guard case let .decorate(primary, _) = decision else {
            Issue.record("expected decorate decision, got \(decision)")
            return
        }
        #expect(primary.route.accountRef == "account-enabled")
    }

    @Test func memoizingReadReturnsStableValuePerAccount() {
        // The cached value, not a fresh read, is returned on repeated calls for
        // the same account; distinct accounts each get their own read.
        var readCount = 0
        let memoized = NotificationServiceSettingsReadPolicy.memoizingLocalNotificationsEnabled { accountRef in
            readCount += 1
            return accountRef == "yes"
        }

        #expect(memoized("yes"))
        #expect(memoized("yes"))
        #expect(!memoized("no"))
        #expect(!memoized("no"))

        // One read per distinct account: "yes" once, "no" once.
        #expect(readCount == 2)
    }

    @Test func archivedLookupsRunOnlyForRecordsPassingCheapPolicyGates() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [
                notificationUpdate(accountRef: "allowed", accountIdHex: hex("11")),
                notificationUpdate(accountRef: "disabled", accountIdHex: hex("22")),
                notificationUpdate(accountRef: "muted", accountIdHex: hex("33")),
                notificationUpdate(
                    accountRef: "mentions-only-plain",
                    accountIdHex: hex("44"),
                    isMention: false
                ),
                notificationUpdate(
                    accountRef: "mentions-only-mention",
                    accountIdHex: hex("44"),
                    isMention: true
                ),
                notificationUpdate(accountRef: "self", accountIdHex: hex("55"), isFromSelf: true),
            ],
            error: nil
        )

        let accounts = NotificationPresentationPolicy.accountRefsRequiringArchivedLookup(
            for: collection,
            localNotificationsEnabled: { $0 != "disabled" },
            notifyMode: { accountIdHex, _ in
                switch accountIdHex {
                case hex("33"): .nothing
                case hex("44"): .mentionsOnly
                default: .all
                }
            }
        )

        #expect(accounts == ["allowed", "mentions-only-mention"])
    }

    @Test func archivedLookupIncludesMutedMentionsOnlyWhenTheyBreakThrough() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [
                notificationUpdate(accountRef: "muted-plain", accountIdHex: hex("33"), isMention: false),
                notificationUpdate(accountRef: "muted-mention", accountIdHex: hex("44"), isMention: true),
                notificationUpdate(
                    accountRef: "muted-self-mention",
                    accountIdHex: hex("55"),
                    isMention: true,
                    isFromSelf: true
                ),
                notificationUpdate(accountRef: "disabled-mention", accountIdHex: hex("66"), isMention: true),
            ],
            error: nil
        )
        let lookup: (Bool) -> Set<String> = { breakThrough in
            NotificationPresentationPolicy.accountRefsRequiringArchivedLookup(
                for: collection,
                localNotificationsEnabled: { $0 != "disabled-mention" },
                notifyMode: { _, _ in .nothing },
                mentionsBreakThroughMute: breakThrough
            )
        }

        #expect(lookup(true) == ["muted-mention"])
        #expect(lookup(false).isEmpty)
    }

    @Test func settingsReadPolicySuppressesOnlyExplicitFalse() {
        #expect(NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
            true
        })
        #expect(!NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
            false
        })
    }

    @Test func settingsReadPolicyFailsOpenOnReadError() {
        #expect(NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
            throw NotificationServiceSettingsReadPolicyTestError.unavailable
        })
    }

    @Test(.tags(.runtime), .marmotRuntimeConcurrencyLimit)
    func notificationServiceStorageReaderProjectsSmallValuesOffMain() async throws {
        try await withTestClient { client in
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: client.relayUrls,
                bootstrapRelays: client.relayUrls
            ).account
            let expected = try await client.notificationSettings(accountRef: account.label)

            let enabled = await NotificationServiceStorageReader.localNotificationsEnabled(
                marmot: client.marmot,
                accountRefs: [account.label]
            )
            let badgeCount = await NotificationServiceStorageReader.applicationBadgeCount(
                marmot: client.marmot
            )

            #expect(enabled[account.label] == expected.localNotificationsEnabled)
            #expect(badgeCount == 0)
        }
    }

    @Test func noDataCollectionKeepsGenericFallback() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .noData,
            notifications: [],
            error: nil
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .fallback)
    }

    @Test func selfOnlyCollectionDeliversQuietly() {
        // The wake carried records and every one was the user's own message;
        // quiet delivery beats an audible generic banner for self content.
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [notificationUpdate(isFromSelf: true)],
            error: nil
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .deliverQuietly)
    }

    @Test func overflowSummariesAreBoundedAcrossManyConversations() {
        // A backlog spread across many chats folds into at most
        // maxOverflowSummaries presentations — the per-conversation summary
        // path must not reintroduce the unbounded add/donate loop.
        let updates = (0..<30).map { index in
            notificationUpdate(
                notificationKey: "overflow-\(index)",
                groupIdHex: hex(String(format: "%02x", index))
            )
        }
        let summaries = NotificationPresentationPolicy.overflowSummaryPresentations(from: updates)
        #expect(summaries.count == NotificationPresentationPolicy.maxOverflowSummaries)
        // Every folded conversation stays represented: per-route counts plus
        // the aggregate tail account for all 30 records.
        #expect(summaries.count <= updates.count)
    }

    @Test func overflowSummariesCarryTheOrOfTheirMembersMentionBits() {
        // A missing bit reads as a mention in willPresent, so an
        // all-non-mention summary must carry an explicit "0" or it banners
        // through a later mentions-only switch.
        let plainSummary = NotificationPresentationPolicy.overflowSummaryPresentations(from: [
            notificationUpdate(notificationKey: "p1"),
            notificationUpdate(notificationKey: "p2"),
        ])
        #expect(plainSummary.count == 1)
        #expect(!LocalNotificationProjection.isMention(from: plainSummary[0].userInfo))

        let mentionSummary = NotificationPresentationPolicy.overflowSummaryPresentations(from: [
            notificationUpdate(notificationKey: "m1"),
            notificationUpdate(notificationKey: "m2", isMention: true),
        ])
        #expect(mentionSummary.count == 1)
        #expect(LocalNotificationProjection.isMention(from: mentionSummary[0].userInfo))
    }

    @Test func presentationPersistsTheMentionBitForWillPresent() {
        let mention = notificationUpdate(notificationKey: "m", isMention: true)
        let plain = notificationUpdate(notificationKey: "p")

        let mentionInfo = LocalNotificationProjection.makePresentation(for: mention)!.userInfo
        let plainInfo = LocalNotificationProjection.makePresentation(for: plain)!.userInfo

        #expect(LocalNotificationProjection.isMention(from: mentionInfo))
        #expect(!LocalNotificationProjection.isMention(from: plainInfo))
        // Pre-upgrade notifications carry no bit; only an explicit
        // non-mention is suppressible by a later mentions-only switch.
        #expect(LocalNotificationProjection.isMention(from: [:]))
    }

    @Test func archivedChatKeysFoldOnlyArchivedRowsPerAccount() {
        let rowA = chatListRow(groupIdHex: "group-a", archived: true, title: "A")
        let rowB = chatListRow(groupIdHex: "group-b", archived: false, title: "B")
        let rowC = chatListRow(groupIdHex: "group-c", archived: true, title: "C")

        let keys = NotificationServiceProjection.archivedChatKeys(rowsByAccountRef: [
            "account-1": [rowA, rowB],
            "account-2": [rowC],
        ])

        #expect(keys.contains(NotificationServiceProjection.archivedChatKey(accountRef: "account-1", groupIdHex: "group-a")))
        #expect(keys.contains(NotificationServiceProjection.archivedChatKey(accountRef: "account-2", groupIdHex: "group-c")))
        #expect(!keys.contains(NotificationServiceProjection.archivedChatKey(accountRef: "account-1", groupIdHex: "group-b")))
        // Keys are account-scoped: another account's archive doesn't leak.
        #expect(!keys.contains(NotificationServiceProjection.archivedChatKey(accountRef: "account-1", groupIdHex: "group-c")))
    }

    @Test func failedCollectionKeepsGenericFallback() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .failed,
            notifications: [],
            error: "relay timeout"
        )

        #expect(NotificationServiceProjection.decision(for: collection) == .fallback)
    }

}

private enum NotificationServiceSettingsReadPolicyTestError: Error {
    case unavailable
}
