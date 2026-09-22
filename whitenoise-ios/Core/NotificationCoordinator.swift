import Foundation
import Observation
import OSLog
import MarmotKit

struct NativePushDisableCoordinator {
    let setNativePushEnabled: (Bool) async throws -> NotificationSettingsFfi
    let clearPushRegistration: () async throws -> Void

    func disable() async throws -> NotificationSettingsFfi {
        let disabledSettings = try await setNativePushEnabled(false)
        do {
            try await clearPushRegistration()
            return disabledSettings
        } catch {
            _ = try? await setNativePushEnabled(true)
            throw error
        }
    }
}

struct NativePushEnableCoordinator {
    let setNativePushEnabled: (Bool) async throws -> NotificationSettingsFfi
    let syncPushRegistration: () async throws -> Void

    func enable() async throws -> NotificationSettingsFfi {
        let enabledSettings = try await setNativePushEnabled(true)
        do {
            try await syncPushRegistration()
            return enabledSettings
        } catch NotificationSettingsActionError.missingApnsToken {
            // APNS token delivery is asynchronous; the app delegate will retry
            // registration as soon as iOS provides the token.
            return enabledSettings
        } catch {
            _ = try? await setNativePushEnabled(false)
            throw error
        }
    }
}

nonisolated enum NativePushRegistrationErrorDisposition {
    case stopSync
    case recordFailure

    static func disposition(for error: Error) -> Self {
        if error is CancellationError { return .stopSync }
        if let settingsError = error as? NotificationSettingsActionError,
           case .missingApnsToken = settingsError {
            return .stopSync
        }
        return .recordFailure
    }
}

nonisolated enum NativePushRelayHintPolicy {
    static func relayHint(
        from config: NativePushServerConfig,
        seedRelays: [String] = AppContainerConfig.seedRelays,
        defaultRelayHint: String = AppContainerConfig.pushNotificationRelayHint
    ) -> String {
        let allowedRelayHints = Set(seedRelays.compactMap(RelayURL.normalized))
        if let relayHint = config.relayHint,
           allowedRelayHints.contains(relayHint) {
            return relayHint
        }
        return RelayURL.normalized(defaultRelayHint) ?? defaultRelayHint
    }
}

nonisolated enum NotificationPresentationRuntimeGate {
    static func canPresent(
        isTaskCancelled: Bool,
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool,
        isSigningOut: Bool,
        hasRuntimeClient: Bool
    ) -> Bool {
        !isTaskCancelled
            && isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
            && !isSigningOut
            && hasRuntimeClient
    }
}

nonisolated struct NotificationArchivedKeysCache {
    private struct Entry {
        let keys: Set<String>
        let readAt: ContinuousClock.Instant
    }

    private var entries: [String: Entry] = [:]

    mutating func keys(
        for accountRef: String,
        now: ContinuousClock.Instant,
        lifetime: Duration
    ) -> Set<String>? {
        guard let entry = entries[accountRef], now - entry.readAt < lifetime else {
            entries.removeValue(forKey: accountRef)
            return nil
        }
        return entry.keys
    }

    mutating func store(
        _ keys: Set<String>,
        for accountRef: String,
        readAt: ContinuousClock.Instant,
        lifetime: Duration
    ) {
        entries = entries.filter { readAt - $0.value.readAt < lifetime }
        entries[accountRef] = Entry(keys: keys, readAt: readAt)
    }
}

nonisolated enum SettingsReadRuntimeGate {
    static func canRead(
        isTaskCancelled: Bool,
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool,
        hasRuntimeClient: Bool
    ) -> Bool {
        !isTaskCancelled
            && isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
            && hasRuntimeClient
    }
}

/// Decision point for whether `scheduleNativePushRegistrationIfEnabled()` may
/// spawn a fresh registration sync. Pure so the guard — including the
/// sign-out window (#320) — is observable in tests without reaching into
/// MainActor-private state. A token-driven reschedule must be suppressed while
/// the scene is inactive, the runtime is suspended/suspending, or a sign-out is
/// tearing down the departing account.
nonisolated enum NativePushRegistrationScheduleGate {
    static func canSchedule(
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool,
        isSigningOut: Bool
    ) -> Bool {
        isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
            && !isSigningOut
    }
}

@MainActor
protocol NotificationCoordinatorHost: AnyObject {
    var phase: AppState.Phase { get }
    var activeAccountRef: String? { get }
    var accounts: [AccountSummaryFfi] { get }
    var client: MarmotClient? { get }
    var notifications: AppNotifications { get }
    var isAppSceneActive: Bool { get }
    var runtimeSuspendedForBackground: Bool { get }
    var isRuntimeSuspendingForNotificationCoordinator: Bool { get }
    var isSigningOutForNotificationCoordinator: Bool { get }
    var visibleChat: VisibleChatRoute? { get }

    func currentMarmotClient() throws -> MarmotClient
    func configureNotifications()
    func present(_ toast: Toast)
}

@MainActor
@Observable
final class NotificationCoordinator {
    @ObservationIgnored private let notificationDriver = NotificationDriver()
    private var nativePushRegistrationTask: Task<Void, Never>?
    private var connectivityCatchUpTask: Task<Void, Never>?
    private var connectivityCatchUpTaskID = UUID()
    private var connectivityRestoredPending = false
    private(set) var isForegroundCatchUpRunning = false
    private var notificationSubscriptionFailureToastPresented = false
    private var nativePushRegistrationFailureToastPresented = false
#if DEBUG
    var foregroundCatchUpOperationForTesting: (() async throws -> Void)?
    var connectivityRestoredOperationForTesting: (() async throws -> Void)?
#endif

    private static let notificationSubscriptionInitialRetryDelayNanoseconds: UInt64 = 1_000_000_000
    private static let notificationSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 60_000_000_000
    private static let pushRegistrationLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "push-registration"
    )
    private static let foregroundCatchUpLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "foreground-resume"
    )

    var notificationSubscriptionActive: Bool { notificationDriver.isRunning }

    @MainActor
    deinit {
        nativePushRegistrationTask?.cancel()
        connectivityCatchUpTask?.cancel()
    }

    func startReadyForegroundMaintenance(
        host: NotificationCoordinatorHost,
        scheduleNativePushRegistration: Bool = true
    ) {
        host.configureNotifications()
        startNotificationSubscription(host: host)
        if scheduleNativePushRegistration {
            scheduleNativePushRegistrationIfEnabled(host: host)
        }
    }

    func startNotificationSubscription(host: NotificationCoordinatorHost) {
        guard let client = host.client else { return }
        let marmot = client.marmot
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: Self.notificationSubscriptionInitialRetryDelayNanoseconds,
            maximumRetryDelayNanoseconds: Self.notificationSubscriptionMaximumRetryDelayNanoseconds,
            subscribe: {
                let subscription = try await marmot.subscribeNotifications()
                return SubscriptionDriver.notifications(subscription)
            },
            present: { [weak self, weak host] update in
                guard let self, let host else { return }
                guard self.canPresentRuntimeNotificationUpdate(host: host) else { return }
                let localNotificationsEnabled = await self.localNotificationsEnabledForPresentation(
                    accountRef: update.accountRef,
                    host: host
                )
                let isArchived = await self.chatIsArchivedForPresentation(update: update, host: host)
                let nativeMuted = await self.chatIsMutedForPresentation(update: update, host: host)
                guard self.canPresentRuntimeNotificationUpdate(host: host) else { return }
                let shouldPresent = await MainActor.run {
                    guard self.canPresentRuntimeNotificationUpdate(host: host) else { return false }
                    // Read at the decision point so a mode change during the
                    // off-main settings read can't present against a stale value.
                    let notifyMode = nativeMuted ? .nothing : ChatMuteStore.notifyMode(
                        accountIdHex: update.accountIdHex,
                        groupIdHex: update.groupIdHex
                    )
                    self.noteNotificationSubscriptionDelivery()
                    return self.shouldPresentLocalNotification(
                        update,
                        localNotificationsEnabled: localNotificationsEnabled,
                        isArchived: isArchived,
                        notifyMode: notifyMode,
                        host: host
                    )
                }
                guard shouldPresent else { return }
                guard self.canPresentRuntimeNotificationUpdate(host: host) else { return }
                await host.notifications.present(update: update)
            },
            reportError: { [weak self, weak host] error in
                guard let self, let host else { return }
                await MainActor.run {
                    self.reportNotificationSubscriptionError(error, host: host)
                }
            }
        )
        notificationDriver.start(runner: runner)
    }

    @discardableResult
    func stopNotificationSubscription() -> Task<Void, Never>? {
        notificationDriver.stop()
    }

    func reportNotificationSubscriptionError(_ error: Error, host: NotificationCoordinatorHost) {
        guard !notificationSubscriptionFailureToastPresented else { return }
        notificationSubscriptionFailureToastPresented = true
        host.present(
            .error(
                L10n.string("Notifications unavailable"),
                message: L10n.string("We'll keep trying in the background.")
            )
        )
    }

    func noteNotificationSubscriptionDelivery() {
        notificationSubscriptionFailureToastPresented = false
    }

    private func shouldPresentLocalNotification(
        _ update: NotificationUpdateFfi,
        localNotificationsEnabled: Bool,
        isArchived: Bool,
        notifyMode: ChatNotifyMode,
        host: NotificationCoordinatorHost
    ) -> Bool {
        LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: localNotificationsEnabled,
            isArchived: isArchived,
            notifyMode: notifyMode,
            isMention: update.isMention,
            appSceneActive: host.isAppSceneActive,
            updateAccountRef: update.accountRef,
            updateGroupIdHex: update.groupIdHex,
            visibleChat: host.visibleChat
        )
    }

    private func canPresentRuntimeNotificationUpdate(host: NotificationCoordinatorHost) -> Bool {
        NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: Task.isCancelled,
            isAppSceneActive: host.isAppSceneActive,
            runtimeSuspendedForBackground: host.runtimeSuspendedForBackground,
            isRuntimeSuspending: host.isRuntimeSuspendingForNotificationCoordinator,
            isSigningOut: host.isSigningOutForNotificationCoordinator,
            hasRuntimeClient: host.client != nil
        )
    }

    private var archivedKeysCache = NotificationArchivedKeysCache()
    /// Long enough to cover a foreground catch-up burst draining buffered
    /// updates back-to-back, short enough that archiving a chat takes effect
    /// on the next real message. Archiving from this device also cancels its
    /// own presentations, so staleness only delays suppression, never data.
    static let archivedKeysCacheLifetime: Duration = .seconds(2)

    static func archivedKeys(from rows: [ChatListRowFfi]) -> Set<String> {
        Set(rows.filter(\.archived).map(\.groupIdHex))
    }

    /// Archived chats keep their history but shed notification attention;
    /// a failed read fails open (presents). The full projection is read once
    /// per burst, not once per update — a catch-up drain delivers many
    /// updates back-to-back and each read is O(all chats).
    private func chatIsArchivedForPresentation(
        update: NotificationUpdateFfi,
        host: NotificationCoordinatorHost
    ) async -> Bool {
        guard !Task.isCancelled,
              host.isAppSceneActive,
              !host.runtimeSuspendedForBackground,
              !host.isRuntimeSuspendingForNotificationCoordinator,
              let client = host.client
        else { return false }
        let now = ContinuousClock.now
        if let keys = archivedKeysCache.keys(
            for: update.accountRef,
            now: now,
            lifetime: Self.archivedKeysCacheLifetime
        ) {
            return keys.contains(update.groupIdHex)
        }
        guard let rows = try? await client.chatList(
            accountRef: update.accountRef,
            includeArchived: true
        ) else { return false }
        let keys = Self.archivedKeys(from: rows)
        archivedKeysCache.store(
            keys,
            for: update.accountRef,
            readAt: ContinuousClock.now,
            lifetime: Self.archivedKeysCacheLifetime
        )
        return keys.contains(update.groupIdHex)
    }

    private func localNotificationsEnabledForPresentation(
        accountRef: String,
        host: NotificationCoordinatorHost
    ) async -> Bool {
        guard !Task.isCancelled,
              host.isAppSceneActive,
              !host.runtimeSuspendedForBackground,
              !host.isRuntimeSuspendingForNotificationCoordinator,
              let client = host.client
        else { return true }
        return await client.localNotificationsEnabledForPresentation(accountRef: accountRef)
    }

    private func chatIsMutedForPresentation(
        update: NotificationUpdateFfi,
        host: NotificationCoordinatorHost
    ) async -> Bool {
        guard let client = foregroundSettingsReadClient(host: host) else { return false }
        return (try? await client.chatNotificationSettings(
            accountRef: update.accountRef, groupIdHex: update.groupIdHex
        ))?.muted ?? false
    }

    func notificationSettings(
        for accountRef: String,
        host: NotificationCoordinatorHost
    ) async -> NotificationSettingsFfi? {
        guard let client = foregroundSettingsReadClient(host: host) else { return nil }
        return try? await client.notificationSettings(accountRef: accountRef)
    }

    func pushRegistration(
        for accountRef: String,
        host: NotificationCoordinatorHost
    ) async -> PushRegistrationFfi? {
        guard let client = foregroundSettingsReadClient(host: host) else { return nil }
        return try? await client.pushRegistration(accountRef: accountRef)
    }

    /// Returns the already-live foreground runtime for settings reads, or nil
    /// while the app is inactive/suspending/suspended. Settings reload tasks can
    /// resume during the background transition; using this helper avoids the
    /// rebuilding `marmot` / `runtimeClient()` accessors so they cannot re-open
    /// the App Group SQLite store after suspension deliberately released it.
    private func foregroundSettingsReadClient(host: NotificationCoordinatorHost) -> MarmotClient? {
        let liveClient = host.client
        guard SettingsReadRuntimeGate.canRead(
            isTaskCancelled: Task.isCancelled,
            isAppSceneActive: host.isAppSceneActive,
            runtimeSuspendedForBackground: host.runtimeSuspendedForBackground,
            isRuntimeSuspending: host.isRuntimeSuspendingForNotificationCoordinator,
            hasRuntimeClient: liveClient != nil
        ), let liveClient
        else { return nil }
        return liveClient
    }

    @discardableResult
    func setLocalNotificationsEnabled(
        _ enabled: Bool,
        host: NotificationCoordinatorHost
    ) async throws -> NotificationSettingsFfi {
        guard let accountRef = host.activeAccountRef else {
            throw NotificationSettingsActionError.noActiveAccount
        }
        if enabled {
            let granted = try await host.notifications.requestAuthorization()
            guard granted else { throw NotificationSettingsActionError.permissionDenied }
        }
        let client = try host.currentMarmotClient()
        return try await client.setLocalNotificationsEnabled(accountRef: accountRef, enabled: enabled)
    }

    @discardableResult
    func setNativePushEnabled(
        _ enabled: Bool,
        host: NotificationCoordinatorHost
    ) async throws -> NotificationSettingsFfi {
        Self.tracePushToggle(enabled ? "enable.begin" : "disable.begin")
        guard let accountRef = host.activeAccountRef else {
            throw NotificationSettingsActionError.noActiveAccount
        }

        if enabled {
            guard NativePushServerConfig.current() != nil else {
                throw NotificationSettingsActionError.nativePushNotConfigured
            }
            Self.tracePushToggle("authorization.begin")
            let granted = try await host.notifications.requestAuthorizationAndRegister()
            Self.tracePushToggle(granted ? "authorization.granted" : "authorization.denied")
            guard granted else { throw NotificationSettingsActionError.permissionDenied }
            return try await enableNativePush(accountRef: accountRef, host: host)
        } else {
            Self.tracePushToggle("disable.drain.begin")
            await cancelNativePushRegistrationTask()
            Self.tracePushToggle("disable.drain.end")
            return try await disableNativePush(accountRef: accountRef, host: host)
        }
    }

    private func enableNativePush(
        accountRef: String,
        host: NotificationCoordinatorHost
    ) async throws -> NotificationSettingsFfi {
        // Mirror the disable path: a background registration sync already in
        // flight must finish (or be cancelled) before this enable issues its
        // own upsert, or two concurrent upsertPushRegistration calls race.
        Self.tracePushToggle("enable.drain.begin")
        await cancelNativePushRegistrationTask()
        Self.tracePushToggle("enable.drain.end")
        let client = try host.currentMarmotClient()
        Self.tracePushToggle("enable.runtime.available")
        let marmot = client.marmot
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { enabled in
                Self.tracePushToggle(enabled ? "enable.preference.on.begin" : "enable.rollback.off.begin")
                let settings = try await marmot.setNativePushEnabled(accountRef: accountRef, enabled: enabled)
                Self.tracePushToggle(enabled ? "enable.preference.on.end" : "enable.rollback.off.end")
                return settings
            },
            // This callback is awaited locally, not stored on either owner.
            // Keep both alive across the preference write and registration.
            syncPushRegistration: { [self, host] in
                Self.tracePushToggle("enable.registration.begin")
                _ = try await self.syncNativePushRegistration(accountRef: accountRef, host: host)
                Self.tracePushToggle("enable.registration.end")
            }
        )
        return try await coordinator.enable()
    }

    private func disableNativePush(
        accountRef: String,
        host: NotificationCoordinatorHost
    ) async throws -> NotificationSettingsFfi {
        let client = try host.currentMarmotClient()
        let marmot = client.marmot
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { enabled in
                Self.tracePushToggle(enabled ? "disable.rollback.on.begin" : "disable.preference.off.begin")
                let settings = try await marmot.setNativePushEnabled(accountRef: accountRef, enabled: enabled)
                Self.tracePushToggle(enabled ? "disable.rollback.on.end" : "disable.preference.off.end")
                return settings
            },
            clearPushRegistration: {
                Self.tracePushToggle("disable.registration.clear.begin")
                _ = try await marmot.clearPushRegistration(accountRef: accountRef)
                Self.tracePushToggle("disable.registration.clear.end")
            }
        )
        return try await coordinator.disable()
    }

    private static func tracePushToggle(_ stage: String) {
        #if DEBUG
        pushRegistrationLog.notice("Push toggle: \(stage, privacy: .public), cancelled=\(Task.isCancelled)")
        #endif
    }

    func enableNotificationsByDefault(
        for accountRef: String,
        host: NotificationCoordinatorHost
    ) async {
        do {
            await cancelNativePushRegistrationTask()
            let granted = try await host.notifications.requestAuthorization()
            try Task.checkCancellation()
            guard granted else {
                _ = try? await host.currentMarmotClient()
                    .setLocalNotificationsEnabled(accountRef: accountRef, enabled: false)
                return
            }

            _ = try await host.currentMarmotClient()
                .setLocalNotificationsEnabled(accountRef: accountRef, enabled: true)
            try Task.checkCancellation()

            guard NativePushServerConfig.current() != nil else { return }
            host.notifications.registerForRemoteNotifications()
            _ = try await enableNativePush(accountRef: accountRef, host: host)
        } catch {
            // Notification defaults are best-effort: account activation should
            // still succeed if iOS permission or push registration is blocked.
        }
    }

    @discardableResult
    func syncNativePushRegistration(
        accountRef: String,
        host: NotificationCoordinatorHost
    ) async throws -> PushRegistrationFfi {
        guard let config = NativePushServerConfig.current() else {
            throw NotificationSettingsActionError.nativePushNotConfigured
        }
        guard let tokenHex = host.notifications.apnsTokenHex, !tokenHex.isEmpty else {
            throw NotificationSettingsActionError.missingApnsToken
        }
        let client = try host.currentMarmotClient()
        return try await client.marmot.upsertPushRegistration(
            accountRef: accountRef,
            platform: .apns,
            rawToken: tokenHex,
            serverPubkeyHex: config.serverPubkeyHex,
            relayHint: NativePushRelayHintPolicy.relayHint(from: config)
        ).registration
    }

    func syncNativePushRegistrationIfEnabled(host: NotificationCoordinatorHost) async {
        guard host.isAppSceneActive,
              !host.runtimeSuspendedForBackground,
              !host.isRuntimeSuspendingForNotificationCoordinator,
              !Task.isCancelled
        else { return }

        let accountRefs = await nativePushEnabledAccountRefs(host: host)
        guard !accountRefs.isEmpty,
              NativePushServerConfig.current() != nil
        else { return }

        if NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: accountRefs,
            currentToken: host.notifications.apnsTokenHex
        ) {
            await host.notifications.registerForRemoteNotificationsIfAuthorized()
        }

        guard host.notifications.apnsTokenHex?.isEmpty == false else { return }

        var lastError: Error?
        for accountRef in accountRefs {
            guard host.isAppSceneActive,
                  !host.runtimeSuspendedForBackground,
                  !host.isRuntimeSuspendingForNotificationCoordinator,
                  !Task.isCancelled
            else { return }

            do {
                _ = try await syncNativePushRegistration(accountRef: accountRef, host: host)
            } catch {
                switch NativePushRegistrationErrorDisposition.disposition(for: error) {
                case .stopSync:
                    return
                case .recordFailure:
                    lastError = error
                }
            }
        }

        if let lastError {
            Self.pushRegistrationLog.warning(
                "Native push registration sync failed: \(String(describing: lastError), privacy: .private)"
            )
            guard !nativePushRegistrationFailureToastPresented else { return }
            nativePushRegistrationFailureToastPresented = true
            host.present(.error(
                L10n.string("Push registration failed"),
                message: L10n.string("We'll keep trying in the background.")
            ))
        } else {
            nativePushRegistrationFailureToastPresented = false
        }
    }

    func scheduleNativePushRegistrationIfEnabled(host: NotificationCoordinatorHost) {
        guard NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: host.isAppSceneActive,
            runtimeSuspendedForBackground: host.runtimeSuspendedForBackground,
            isRuntimeSuspending: host.isRuntimeSuspendingForNotificationCoordinator,
            isSigningOut: host.isSigningOutForNotificationCoordinator
        ) else { return }
        let previousTask = nativePushRegistrationTask
        previousTask?.cancel()
        nativePushRegistrationTask = Task { [weak self, weak host] in
            // Drain the prior (now-cancelled) registration task before starting
            // a fresh sync so overlapping per-account upsertPushRegistration FFI
            // writes cannot run concurrently. The per-account loop only checks
            // Task.isCancelled *between* accounts, so without this await a
            // reschedule (e.g. on token arrival) could issue two concurrent
            // upsertPushRegistration calls. Mirrors cancelNativePushRegistrationTask().
            await previousTask?.value
            guard let self, let host else { return }
            await self.syncNativePushRegistrationIfEnabled(host: host)
        }
    }

    func cancelNativePushRegistrationTaskWithoutAwaiting() {
        nativePushRegistrationTask?.cancel()
    }

    func cancelNativePushRegistrationTask() async {
        let task = nativePushRegistrationTask
        nativePushRegistrationTask = nil
        task?.cancel()
        await task?.value
    }

    func catchUpAfterForegroundActivation(host: NotificationCoordinatorHost) async {
        guard ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: host.phase,
            isCatchUpRunning: isForegroundCatchUpRunning,
            isAppSceneActive: host.isAppSceneActive,
            runtimeSuspendedForBackground: host.runtimeSuspendedForBackground,
            isRuntimeSuspending: host.isRuntimeSuspendingForNotificationCoordinator
        ) else { return }

        isForegroundCatchUpRunning = true
        defer { isForegroundCatchUpRunning = false }
        let startedAt = ContinuousClock.now
        var outcome = "cancelled"
        defer {
            let elapsed = startedAt.duration(to: ContinuousClock.now).components
            let elapsedMilliseconds = Double(elapsed.seconds) * 1_000
                + Double(elapsed.attoseconds) / 1_000_000_000_000_000
            Self.foregroundCatchUpLog.info(
                "catch_up outcome=\(outcome, privacy: .public) duration_ms=\(elapsedMilliseconds, format: .fixed(precision: 0), privacy: .public)"
            )
        }

        guard !Task.isCancelled else { return }

        do {
#if DEBUG
            if let foregroundCatchUpOperationForTesting {
                try await foregroundCatchUpOperationForTesting()
            } else {
                try await host.currentMarmotClient().catchUpAccounts()
            }
#else
            try await host.currentMarmotClient().catchUpAccounts()
#endif
            try Task.checkCancellation()
            outcome = "succeeded"
        } catch is CancellationError {
            outcome = "cancelled"
        } catch {
            outcome = "failed"
            // Foreground catch-up is a best-effort safety net. The live
            // subscription and NSE path continue to handle notification flow.
        }
    }

    func scheduleConnectivityCatchUp(
        host: NotificationCoordinatorHost,
        connectivityRestored: Bool = false
    ) {
        connectivityRestoredPending = connectivityRestoredPending || connectivityRestored
        guard connectivityCatchUpTask == nil else { return }
        let id = UUID()
        connectivityCatchUpTaskID = id
        connectivityCatchUpTask = Task { [weak self, weak host] in
            guard let self else { return }
            defer { self.clearCompletedConnectivityCatchUp(id: id) }
            guard let host else { return }
            repeat {
                guard self.connectivityCatchUpTaskID == id else { return }
                let shouldWakeDurableRetries = self.connectivityRestoredPending
                self.connectivityRestoredPending = false
                if shouldWakeDurableRetries {
                    await self.notifyConnectivityRestored(host: host)
                }
                await self.catchUpAfterForegroundActivation(host: host)
            } while self.connectivityCatchUpTaskID == id && self.connectivityRestoredPending
        }
    }

    private func notifyConnectivityRestored(host: NotificationCoordinatorHost) async {
        do {
#if DEBUG
            if let connectivityRestoredOperationForTesting {
                try await connectivityRestoredOperationForTesting()
            } else {
                try await host.currentMarmotClient().notifyConnectivityRestored()
            }
#else
            try await host.currentMarmotClient().notifyConnectivityRestored()
#endif
        } catch {
            // Best effort. The following catch-up and MDK's durable retry
            // scheduler remain available if the runtime changed underneath us.
        }
    }

    func cancelConnectivityCatchUpWithoutAwaiting() -> Task<Void, Never>? {
        let task = connectivityCatchUpTask
        connectivityCatchUpTask = nil
        connectivityCatchUpTaskID = UUID()
        connectivityRestoredPending = false
        task?.cancel()
        return task
    }

    private func clearCompletedConnectivityCatchUp(id: UUID) {
        guard connectivityCatchUpTaskID == id else { return }
        connectivityCatchUpTask = nil
    }

    static func nativePushEnabledAccountRefs(
        accountRefs: [String],
        runtimeClient: () throws -> MarmotClient
    ) async -> [String] {
        do {
            let client = try runtimeClient()
            return await client.nativePushEnabledAccountRefs(accountRefs: accountRefs)
        } catch {
            // Native push sync is best-effort; skip this pass and retry on the
            // next foreground/token event once runtime rebuild succeeds.
            return []
        }
    }

    private func nativePushEnabledAccountRefs(host: NotificationCoordinatorHost) async -> [String] {
        guard let client = foregroundSettingsReadClient(host: host) else { return [] }
        return await client.nativePushEnabledAccountRefs(accountRefs: host.accounts.map(\.label))
    }

    #if DEBUG
    func nativePushEnabledAccountRefsForTesting(host: NotificationCoordinatorHost) async -> [String] {
        await nativePushEnabledAccountRefs(host: host)
    }

    func drainNativePushRegistrationTaskForTesting() async {
        await nativePushRegistrationTask?.value
    }

    func drainConnectivityCatchUpTaskForTesting() async {
        await connectivityCatchUpTask?.value
    }

    var hasConnectivityCatchUpTaskForTesting: Bool {
        connectivityCatchUpTask != nil
    }
    #endif
}
