import Foundation
import MarmotKit

nonisolated enum NotificationPresentationPolicy {
    static let maxAdditionalPresentations = 8

    static func shouldPresent(
        localNotificationsEnabled: Bool,
        isArchived: Bool = false,
        notifyMode: ChatNotifyMode = .all,
        isMention: Bool = false,
        appSceneActive: Bool,
        updateAccountRef: String,
        updateGroupIdHex: String,
        visibleAccountRef: String?,
        visibleGroupIdHex: String?
    ) -> Bool {
        guard localNotificationsEnabled, !isArchived else { return false }
        switch notifyMode {
        case .all:
            break
        case .mentionsOnly:
            guard isMention else { return false }
        case .nothing:
            return false
        }
        guard appSceneActive else { return true }
        guard let visibleAccountRef, let visibleGroupIdHex else { return true }
        return visibleAccountRef != updateAccountRef
            || visibleGroupIdHex != updateGroupIdHex
    }

    /// `notifyMode` is keyed by (accountIdHex, groupIdHex) — the mute store's
    /// key — unlike `isArchived`, which takes the update's accountRef.
    static func serviceDecision(
        for collection: BackgroundNotificationCollectionFfi,
        localNotificationsEnabled: (String) -> Bool = { _ in true },
        isArchived: (String, String) -> Bool = { _, _ in false },
        notifyMode: (String, String) -> ChatNotifyMode = { _, _ in .all },
        nickname: (String, String) -> String? = { _, _ in nil },
        previewMode: NotificationPreviewMode = .senderAndMessage
    ) -> NotificationServiceRenderDecision {
        switch collection.status {
        case .newData:
            let updates = orderedPresentableUpdates(
                collection.notifications,
                localNotificationsEnabled: localNotificationsEnabled,
                isArchived: isArchived
            )
            let allowedUpdates = updates.filter { update in
                switch notifyMode(update.accountIdHex, update.groupIdHex) {
                case .all: true
                case .mentionsOnly: update.isMention
                case .nothing: false
                }
            }
            // The alert that woke the extension cannot be dropped, so a wake
            // whose every record is suppressed — muted or mentions-only chats,
            // disabled local notifications, archived chats, self-messages —
            // delivers quietly instead of falling back to audible generic
            // content the user asked not to hear.
            if allowedUpdates.isEmpty, !collection.notifications.isEmpty {
                return .deliverQuietly
            }
            guard let primaryUpdate = allowedUpdates.first,
                  let primary = LocalNotificationProjection.makePresentation(
                      for: primaryUpdate,
                      nickname: nickname,
                      previewMode: previewMode
                  )
            else {
                return .fallback
            }
            return .decorate(
                primary,
                additionalPresentations: boundedAdditionalPresentations(
                    from: Array(allowedUpdates.dropFirst()),
                    nickname: nickname,
                    previewMode: previewMode
                )
            )
        case .noData, .failed:
            return .fallback
        }
    }

    /// Accounts whose records survive every cheap policy gate and therefore
    /// need the NSE's comparatively expensive full chat-list read to resolve
    /// archived state.
    static func accountRefsRequiringArchivedLookup(
        for collection: BackgroundNotificationCollectionFfi,
        localNotificationsEnabled: (String) -> Bool = { _ in true },
        notifyMode: (String, String) -> ChatNotifyMode = { _, _ in .all }
    ) -> Set<String> {
        Set(collection.notifications.compactMap { update in
            guard !update.isFromSelf,
                  localNotificationsEnabled(update.accountRef)
            else { return nil }
            switch notifyMode(update.accountIdHex, update.groupIdHex) {
            case .all:
                return update.accountRef
            case .mentionsOnly:
                return update.isMention ? update.accountRef : nil
            case .nothing:
                return nil
            }
        })
    }

    static func orderedPresentableUpdates(
        _ updates: [NotificationUpdateFfi],
        localNotificationsEnabled: (String) -> Bool = { _ in true },
        isArchived: (String, String) -> Bool = { _, _ in false }
    ) -> [NotificationUpdateFfi] {
        updates
            .filter { update in
                shouldPresent(
                    localNotificationsEnabled: localNotificationsEnabled(update.accountRef),
                    isArchived: isArchived(update.accountRef, update.groupIdHex),
                    appSceneActive: false,
                    updateAccountRef: update.accountRef,
                    updateGroupIdHex: update.groupIdHex,
                    visibleAccountRef: nil,
                    visibleGroupIdHex: nil
                ) && !update.isFromSelf
            }
            .sorted(by: orderedBefore)
    }

    // Caps how many additional records the NSE adds individually and folds any
    // overflow into per-route summary presentations. The overflow records have
    // already been consumed from Marmot's background notification cursor, so
    // they must stay represented rather than be silently abandoned; the summary
    // keeps the consumed-cursor count visible without an unbounded `add` loop.
    static func boundedAdditionalPresentations(
        from additionalUpdates: [NotificationUpdateFfi],
        nickname: (String, String) -> String? = { _, _ in nil },
        previewMode: NotificationPreviewMode = .senderAndMessage
    ) -> [LocalNotificationPresentation] {
        guard additionalUpdates.count > maxAdditionalPresentations + 1 else {
            return additionalUpdates.compactMap {
                LocalNotificationProjection.makePresentation(
                    for: $0,
                    nickname: nickname,
                    previewMode: previewMode
                )
            }
        }

        let shownUpdates = Array(additionalUpdates.prefix(maxAdditionalPresentations))
        let overflowUpdates = Array(additionalUpdates.dropFirst(maxAdditionalPresentations))
        return shownUpdates.compactMap {
            LocalNotificationProjection.makePresentation(
                for: $0,
                nickname: nickname,
                previewMode: previewMode
            )
        }
            + overflowSummaryPresentations(
                from: overflowUpdates,
                nickname: nickname,
                previewMode: previewMode
            )
    }

    static func overflowSummaryPresentations(
        from overflowUpdates: [NotificationUpdateFfi],
        nickname: (String, String) -> String? = { _, _ in nil },
        previewMode: NotificationPreviewMode = .senderAndMessage
    ) -> [LocalNotificationPresentation] {
        var buckets: [OverflowRouteKey: (first: NotificationUpdateFfi, count: Int, containsMention: Bool)] = [:]
        var order: [OverflowRouteKey] = []
        for update in overflowUpdates {
            let key = OverflowRouteKey(update)
            if let existing = buckets[key] {
                buckets[key] = (existing.first, existing.count + 1, existing.containsMention || update.isMention)
            } else {
                buckets[key] = (update, 1, update.isMention)
                order.append(key)
            }
        }

        // One summary per conversation is itself unbounded — a backlog spread
        // across many chats would reintroduce the very add()/donate() flood
        // the cap exists to prevent. Distinct-route summaries are bounded and
        // the tail folds into one aggregate (its route points at the first
        // folded chat; any tap opens the app, which catches up fully).
        var boundedOrder = order
        var aggregate: (first: NotificationUpdateFfi, count: Int, containsMention: Bool)?
        if order.count > maxOverflowSummaries {
            let tail = order.dropFirst(maxOverflowSummaries - 1)
            boundedOrder = Array(order.prefix(maxOverflowSummaries - 1))
            let tailBuckets = tail.compactMap { buckets[$0] }
            if let firstTail = tailBuckets.first {
                aggregate = (
                    first: firstTail.first,
                    count: tailBuckets.reduce(0) { $0 + $1.count },
                    containsMention: tailBuckets.contains { $0.containsMention }
                )
            }
        }

        var summaries = boundedOrder.compactMap { key -> LocalNotificationPresentation? in
            guard let bucket = buckets[key],
                  let base = LocalNotificationProjection.makePresentation(
                      for: bucket.first,
                      nickname: nickname,
                      previewMode: previewMode
                  )
            else { return nil }
            return summaryPresentation(
                after: base,
                overflowCount: bucket.count,
                containsMention: bucket.containsMention
            )
        }
        if let aggregate,
           let base = LocalNotificationProjection.makePresentation(
               for: aggregate.first,
               nickname: nickname,
               previewMode: previewMode
           ) {
            summaries.append(summaryPresentation(
                after: base,
                overflowCount: aggregate.count,
                containsMention: aggregate.containsMention
            ))
        }
        return summaries
    }

    /// Upper bound on distinct-conversation overflow summaries per wake.
    static let maxOverflowSummaries = maxAdditionalPresentations

    /// The summary inherits the OR of its members' mention bits: a missing
    /// bit reads as a mention in `willPresent`, so an all-non-mention summary
    /// would banner through a later mentions-only switch.
    static func summaryPresentation(
        after base: LocalNotificationPresentation,
        overflowCount: Int,
        containsMention: Bool
    ) -> LocalNotificationPresentation {
        let route = LocalNotificationRoute(
            accountRef: base.route.accountRef,
            groupIdHex: base.route.groupIdHex,
            notificationKey: "\(base.route.notificationKey):+\(overflowCount)-more",
            messageIdHex: nil
        )

        return LocalNotificationPresentation(
            identifier: route.notificationKey,
            threadIdentifier: base.threadIdentifier,
            title: L10n.string("White Noise"),
            body: L10n.plural("%lld more messages", Int64(overflowCount)),
            route: route,
            timestamp: base.timestamp,
            userInfo: LocalNotificationProjection.userInfo(for: route).merging(
                [
                    LocalNotificationProjection.isMentionKey: containsMention ? "1" : "0",
                    LocalNotificationProjection.accountIdHexKey:
                        base.userInfo[LocalNotificationProjection.accountIdHexKey] ?? "",
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
    }

    private static func orderedBefore(
        _ lhs: NotificationUpdateFfi,
        _ rhs: NotificationUpdateFfi
    ) -> Bool {
        if lhs.timestampMs != rhs.timestampMs {
            return lhs.timestampMs > rhs.timestampMs
        }
        return stableSortKey(lhs) < stableSortKey(rhs)
    }

    private static func stableSortKey(_ update: NotificationUpdateFfi) -> String {
        [
            update.accountRef,
            update.groupIdHex,
            update.conversationKey,
            update.notificationKey,
            update.messageIdHex ?? "",
            update.sender.accountIdHex
        ].joined(separator: "|")
    }

    private struct OverflowRouteKey: Hashable {
        let accountRef: String
        let groupIdHex: String
        let threadIdentifier: String

        init(_ update: NotificationUpdateFfi) {
            accountRef = update.accountRef
            groupIdHex = update.groupIdHex
            threadIdentifier = update.conversationKey.isEmpty
                ? "\(update.accountRef):\(update.groupIdHex)"
                : update.conversationKey
        }
    }
}
