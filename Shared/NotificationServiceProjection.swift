import Foundation
import MarmotKit

nonisolated enum NotificationServiceRenderDecision: Equatable {
    case decorate(LocalNotificationPresentation, additionalPresentations: [LocalNotificationPresentation])
    /// Every presentable record in the wake belongs to a muted chat. The alert
    /// that woke the extension must still be delivered, but with generic
    /// content and no banner or sound.
    case deliverQuietly
    case fallback

    var diagnosticOutcome: NotificationServiceDiagnosticOutcome {
        switch self {
        case .decorate:
            .decorated
        case .deliverQuietly:
            .quiet
        case .fallback:
            .fallback
        }
    }
}

nonisolated enum NotificationServiceDiagnosticStage: String, Codable, Equatable {
    case received
    case runtimeCreated
    case runtimeStarted
    case collectionCompleted
    case rendered
}

nonisolated enum NotificationServiceDiagnosticOutcome: String, Codable, Equatable {
    case decorated
    case quiet
    case fallback
    case failed
    case runtimeOwnershipContention
    case expired
}

/// A privacy-safe breadcrumb for diagnosing NSE execution on a physical device.
/// It deliberately excludes account, group, sender, message, and error details.
nonisolated struct NotificationServiceDiagnosticSnapshot: Codable, Equatable {
    let recordedAt: Date
    let durationMilliseconds: Int
    let stage: NotificationServiceDiagnosticStage
    let outcome: NotificationServiceDiagnosticOutcome
    let notificationCount: Int
}

nonisolated enum NotificationServiceDiagnostics {
    private static let snapshotKey = "notificationService.lastDiagnosticSnapshot.v1"

    static func record(
        _ snapshot: NotificationServiceDiagnosticSnapshot,
        defaults: UserDefaults
    ) {
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(encoded, forKey: snapshotKey)
    }

    static func lastSnapshot(defaults: UserDefaults) -> NotificationServiceDiagnosticSnapshot? {
        guard let encoded = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(
            NotificationServiceDiagnosticSnapshot.self,
            from: encoded
        )
    }

    static func recordInSharedContainer(_ snapshot: NotificationServiceDiagnosticSnapshot) {
        guard let defaults = UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier) else {
            return
        }
        record(snapshot, defaults: defaults)
    }

    static func lastSnapshotInSharedContainer() -> NotificationServiceDiagnosticSnapshot? {
        guard let defaults = UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier) else {
            return nil
        }
        return lastSnapshot(defaults: defaults)
    }
}

nonisolated enum NotificationServiceTimeoutPolicy {
    /// Leaves enough of the system-owned NSE window to stop workers and close
    /// SQLite before iOS is allowed to suspend the extension.
    static let proactiveExpirationDelay: Duration = .seconds(18)

    static func shouldApplyTimeoutFallback(
        applyingFallbackForTimeout: Bool,
        didApplyRenderDecision: Bool
    ) -> Bool {
        applyingFallbackForTimeout && !didApplyRenderDecision
    }

    static func canDeliver(
        expirationInProgress: Bool,
        completingExpiration: Bool
    ) -> Bool {
        !expirationInProgress || completingExpiration
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

/// Runs the NSE's synchronous storage projections away from its MainActor so
/// `serviceExtensionTimeWillExpire()` can begin terminal cleanup even if a
/// SQLite read is slow. Only small Sendable values cross back to the extension.
nonisolated enum NotificationServiceStorageReader {
    static func applicationBadgeCount(marmot: Marmot) async -> Int? {
        await offMain {
            guard let summaries = try? marmot.accountUnreadSummary() else { return nil }
            return ApplicationBadgeCountProjection.count(for: summaries)
        }
    }

    static func localNotificationsEnabled(
        marmot: Marmot,
        accountRefs: Set<String>
    ) async -> [String: Bool] {
        await offMain {
            var settings: [String: Bool] = [:]
            for accountRef in accountRefs {
                guard !Task.isCancelled else { break }
                settings[accountRef] = NotificationServiceSettingsReadPolicy
                    .localNotificationsEnabled {
                        try marmot.notificationSettings(
                            accountRef: accountRef
                        ).localNotificationsEnabled
                    }
            }
            return settings
        }
    }

    static func archivedChatKeys(
        marmot: Marmot,
        accountRefs: Set<String>
    ) async -> Set<String> {
        await offMain {
            var rowsByAccountRef: [String: [ChatListRowFfi]] = [:]
            for accountRef in accountRefs {
                guard !Task.isCancelled else { break }
                rowsByAccountRef[accountRef] =
                    (try? marmot.chatList(accountRef: accountRef, includeArchived: true)) ?? []
            }
            return NotificationServiceProjection.archivedChatKeys(
                rowsByAccountRef: rowsByAccountRef
            )
        }
    }

    private static func offMain<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
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
    static let maxAdditionalPresentations = NotificationPresentationPolicy.maxAdditionalPresentations

    /// Archived state is read once per wake as full chat lists (one sync
    /// storage read per account) and folded into a key set the decision's
    /// resolver checks; a throwing read contributes nothing (fail open —
    /// archived suppression is attention hygiene, not privacy).
    static func archivedChatKeys(rowsByAccountRef: [String: [ChatListRowFfi]]) -> Set<String> {
        var keys: Set<String> = []
        for (accountRef, rows) in rowsByAccountRef {
            for row in rows where row.archived {
                keys.insert(archivedChatKey(accountRef: accountRef, groupIdHex: row.groupIdHex))
            }
        }
        return keys
    }

    static func archivedChatKey(accountRef: String, groupIdHex: String) -> String {
        "\(accountRef)\u{0}\(groupIdHex)"
    }

    static func decision(
        for collection: BackgroundNotificationCollectionFfi,
        localNotificationsEnabled: (String) -> Bool = { _ in true },
        isArchived: (String, String) -> Bool = { _, _ in false },
        notifyMode: (String, String) -> ChatNotifyMode = { _, _ in .all },
        nickname: (String, String) -> String? = { _, _ in nil },
        previewMode: NotificationPreviewMode = .senderAndMessage
    ) -> NotificationServiceRenderDecision {
        NotificationPresentationPolicy.serviceDecision(
            for: collection,
            localNotificationsEnabled: localNotificationsEnabled,
            isArchived: isArchived,
            notifyMode: notifyMode,
            nickname: nickname,
            previewMode: previewMode
        )
    }

}
