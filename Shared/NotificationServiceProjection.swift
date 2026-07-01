import Foundation
import MarmotKit

enum NotificationServiceRenderDecision: Equatable {
    case decorate(LocalNotificationPresentation, additionalPresentations: [LocalNotificationPresentation])
    case fallback
}

nonisolated enum NotificationServiceTimeoutPolicy {
    static func shouldApplyTimeoutFallback(
        applyingFallbackForTimeout: Bool,
        didApplyRenderDecision: Bool
    ) -> Bool {
        applyingFallbackForTimeout && !didApplyRenderDecision
    }
}

nonisolated enum NotificationServiceSettingsReadPolicy {
    static func localNotificationsEnabled(readSetting: () throws -> Bool) -> Bool {
        do {
            return try readSetting()
        } catch {
            return true
        }
    }

    // `decision` invokes the `localNotificationsEnabled` predicate once per
    // record while filtering. The NSE's underlying predicate is a synchronous
    // `marmot.notificationSettings(accountRef:)` FFI read + decode, so an offline
    // backlog of N records issues N FFI reads inside the extension's tight (~8 s)
    // wake budget even though distinct accounts are typically 1–2. Wrap the read
    // so each distinct `accountRef` is resolved at most once per wake. The
    // predicate runs single-threaded on the NSE's MainActor while `decision`
    // filters synchronously, so a captured plain dictionary needs no locking.
    static func memoizingLocalNotificationsEnabled(
        read: @escaping (String) -> Bool
    ) -> (String) -> Bool {
        var cache: [String: Bool] = [:]
        return { accountRef in
            if let cached = cache[accountRef] {
                return cached
            }
            let resolved = read(accountRef)
            cache[accountRef] = resolved
            return resolved
        }
    }
}

nonisolated enum NotificationServiceProjection {
    // Keep room for extension startup and fallback delivery before iOS expires
    // the notification service extension.
    static let maxWakeWaitMs: UInt32 = 8_000

    // Upper bound on the number of *additional* message presentations the NSE
    // adds individually (the primary presentation woke the extension and is not
    // counted here). A large offline backlog can make `collectNotificationsAfterWake`
    // return dozens or hundreds of records; issuing one `UNUserNotificationCenter.add`
    // per record inside the extension's tight time budget risks expiration and floods
    // the user. Mirrors the bounding applied to other large/untrusted collections
    // (e.g. `DuckDuckGoImageSearchClient.maximumResultCount`).
    static let maxAdditionalPresentations = 8

    static func decision(
        for collection: BackgroundNotificationCollectionFfi,
        localNotificationsEnabled: (String) -> Bool = { _ in true }
    ) -> NotificationServiceRenderDecision {
        switch collection.status {
        case .newData:
            let presentations = collection.notifications
                .filter({ !$0.isFromSelf && localNotificationsEnabled($0.accountRef) })
                .sorted(by: { $0.timestampMs > $1.timestampMs })
                .compactMap(LocalNotificationProjection.makePresentation(for:))
            guard let presentation = presentations.first
            else {
                // An NSE cannot cancel an alerting APNS push after delivery; a
                // generic fallback is safer than handing iOS blank content.
                return .fallback
            }
            return .decorate(
                presentation,
                additionalPresentations: boundedAdditionalPresentations(
                    after: presentation,
                    from: Array(presentations.dropFirst())
                )
            )
        case .noData:
            return .fallback
        case .failed:
            return .fallback
        }
    }

    // Caps how many additional records the NSE adds individually and folds any
    // overflow into a single summary presentation. The overflow records have
    // already been consumed from Marmot's background notification cursor, so they
    // must stay represented rather than be silently abandoned; the summary keeps
    // the consumed-cursor count visible without an unbounded `add` loop.
    static func boundedAdditionalPresentations(
        after primary: LocalNotificationPresentation,
        from additional: [LocalNotificationPresentation]
    ) -> [LocalNotificationPresentation] {
        guard additional.count > maxAdditionalPresentations else {
            return additional
        }

        let shown = Array(additional.prefix(maxAdditionalPresentations))
        let overflowCount = additional.count - shown.count
        guard overflowCount > 0 else { return shown }

        return shown + [summaryPresentation(after: primary, overflowCount: overflowCount)]
    }

    static func summaryPresentation(
        after primary: LocalNotificationPresentation,
        overflowCount: Int
    ) -> LocalNotificationPresentation {
        // Route the summary to the newest conversation so a tap opens somewhere
        // sane, but give it a distinct synthetic key so it never collides with or
        // dedupes against a real message presentation. No message content is
        // included; only a coalesced count, so nothing extra is leaked.
        let route = LocalNotificationRoute(
            accountRef: primary.route.accountRef,
            groupIdHex: primary.route.groupIdHex,
            notificationKey: "\(primary.route.notificationKey):+\(overflowCount)-more",
            messageIdHex: nil
        )

        return LocalNotificationPresentation(
            identifier: route.notificationKey,
            threadIdentifier: primary.threadIdentifier,
            title: L10n.string("White Noise"),
            body: L10n.plural("%lld more messages", Int64(overflowCount)),
            route: route,
            timestamp: primary.timestamp,
            userInfo: LocalNotificationProjection.userInfo(for: route)
        )
    }
}
