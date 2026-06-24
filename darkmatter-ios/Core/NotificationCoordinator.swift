import Foundation
import Observation
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

nonisolated enum NotificationPresentationRuntimeGate {
    static func canPresent(
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
    var marmot: Marmot { get }
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
    private var isForegroundCatchUpRunning = false
    private var notificationSubscriptionFailureToastPresented = false

    private static let notificationSubscriptionInitialRetryDelayNanoseconds: UInt64 = 1_000_000_000
    private static let notificationSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 60_000_000_000

    var notificationSubscriptionActive: Bool { notificationDriver.isRunning }

    deinit {
        nativePushRegistrationTask?.cancel()
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
        notificationSubscriptionFailureToastPresented = false
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: Self.notificationSubscriptionInitialRetryDelayNanoseconds,
            maximumRetryDelayNanoseconds: Self.notificationSubscriptionMaximumRetryDelayNanoseconds,
            subscribe: { [weak host] in
                guard let host else { throw CancellationError() }
                let subscription = try await host.marmot.subscribeNotifications()
                return SubscriptionDriver.notifications(subscription)
            },
            present: { [weak self, weak host] update in
                guard let self, let host else { return }
                guard self.canPresentRuntimeNotificationUpdate(host: host) else { return }
                let localNotificationsEnabled = await self.localNotificationsEnabledForPresentation(
                    accountRef: update.accountRef,
                    host: host
                )
                guard self.canPresentRuntimeNotificationUpdate(host: host) else { return }
                let shouldPresent = await MainActor.run {
                    guard self.canPresentRuntimeNotificationUpdate(host: host) else { return false }
                    self.noteNotificationSubscriptionDelivery()
                    return self.shouldPresentLocalNotification(
                        update,
                        localNotificationsEnabled: localNotificationsEnabled,
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

    func stopNotificationSubscription() {
        notificationDriver.stop()
        notificationSubscriptionFailureToastPresented = false
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
        host: NotificationCoordinatorHost
    ) -> Bool {
        LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: localNotificationsEnabled,
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
            hasRuntimeClient: host.client != nil
        )
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
        return try host.marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: enabled)
    }

    @discardableResult
    func setNativePushEnabled(
        _ enabled: Bool,
        host: NotificationCoordinatorHost
    ) async throws -> NotificationSettingsFfi {
        guard let accountRef = host.activeAccountRef else {
            throw NotificationSettingsActionError.noActiveAccount
        }

        if enabled {
            guard NativePushServerConfig.current() != nil else {
                throw NotificationSettingsActionError.nativePushNotConfigured
            }
            let granted = try await host.notifications.requestAuthorizationAndRegister()
            guard granted else { throw NotificationSettingsActionError.permissionDenied }
            return try await enableNativePush(accountRef: accountRef, host: host)
        } else {
            return try await disableNativePush(accountRef: accountRef, host: host)
        }
    }

    private func enableNativePush(
        accountRef: String,
        host: NotificationCoordinatorHost
    ) async throws -> NotificationSettingsFfi {
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { [weak host] enabled in
                guard let host else { throw CancellationError() }
                return try await host.marmot.setNativePushEnabled(accountRef: accountRef, enabled: enabled)
            },
            syncPushRegistration: { [weak self, weak host] in
                guard let self, let host else { throw CancellationError() }
                _ = try await self.syncNativePushRegistration(accountRef: accountRef, host: host)
            }
        )
        return try await coordinator.enable()
    }

    private func disableNativePush(
        accountRef: String,
        host: NotificationCoordinatorHost
    ) async throws -> NotificationSettingsFfi {
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { [weak host] enabled in
                guard let host else { throw CancellationError() }
                return try await host.marmot.setNativePushEnabled(accountRef: accountRef, enabled: enabled)
            },
            clearPushRegistration: { [weak host] in
                guard let host else { throw CancellationError() }
                try await host.marmot.clearPushRegistration(accountRef: accountRef)
            }
        )
        return try await coordinator.disable()
    }

    func enableNotificationsByDefault(
        for accountRef: String,
        host: NotificationCoordinatorHost
    ) async {
        do {
            let granted = try await host.notifications.requestAuthorization()
            guard granted else {
                _ = try? host.marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: false)
                return
            }

            _ = try host.marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: true)

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
        return try await host.marmot.upsertPushRegistration(
            accountRef: accountRef,
            platform: .apns,
            rawToken: tokenHex,
            serverPubkeyHex: config.serverPubkeyHex,
            relayHint: Self.pushRegistrationRelayHint(from: config)
        )
    }

    private static func pushRegistrationRelayHint(from config: NativePushServerConfig) -> String {
        if let relayHint = config.relayHint,
           AppContainerConfig.seedRelays.contains(relayHint) {
            return relayHint
        }
        return AppContainerConfig.pushNotificationRelayHint
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
            host.present(.error(L10n.string("Push registration failed"), message: lastError.localizedDescription))
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

        do {
            try await host.marmot.catchUpAccounts()
        } catch {
            // Foreground catch-up is a best-effort safety net. The live
            // subscription and NSE path continue to handle notification flow.
        }
    }

    func setAppSceneActive(_ active: Bool) {
        if !active {
            cancelNativePushRegistrationTaskWithoutAwaiting()
        }
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
        await Self.nativePushEnabledAccountRefs(
            accountRefs: host.accounts.map(\.label),
            runtimeClient: { try host.currentMarmotClient() }
        )
    }

    #if DEBUG
    func drainNativePushRegistrationTaskForTesting() async {
        await nativePushRegistrationTask?.value
    }
    #endif
}
