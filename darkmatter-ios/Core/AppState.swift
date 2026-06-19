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

/// Root observable state for the app.
///
/// Holds the `Marmot` handle, the current set of `AccountSummaryFfi`, and
/// which account is active. View models observe this through
/// `@Environment(AppState.self)`. Subscriptions and sends are always
/// performed against `activeAccountRef`.
@Observable
final class AppState {

    enum Phase: Equatable {
        case bootstrapping
        case onboarding
        case ready
        case failed(String)
    }

    typealias ProfileLink = AppProfileLink

    /// Where the user is in the global flow. Drives the root router.
    private(set) var phase: Phase = .bootstrapping

    /// All accounts known to marmot-app, refreshed after every account-changing call.
    private(set) var accounts: [AccountSummaryFfi] = []

    /// The account whose chats / messages are currently displayed.
    /// `nil` only between bootstrap and onboarding completion.
    var activeAccountRef: String? {
        didSet {
            if let ref = activeAccountRef {
                UserDefaults.standard.set(ref, forKey: Self.activeAccountKey)
            } else {
                // Clearing the ref (e.g. signing out of the only account)
                // must remove the persisted value, otherwise the next launch
                // resurrects the signed-out account from UserDefaults.
                UserDefaults.standard.removeObject(forKey: Self.activeAccountKey)
            }
        }
    }

    /// Developer mode: surfaces extra debugging UI (e.g. MLS group internals
    /// on the chat-details screen). Off by default; toggled in Settings.
    var developerMode: Bool {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: Self.developerModeKey)
        }
    }

    /// When developer mode is on, show every MLS/stream event in the
    /// conversation timeline with debug styling (kinds 1200+, reactions, etc.).
    var streamingDebugMode: Bool {
        didSet {
            UserDefaults.standard.set(streamingDebugMode, forKey: Self.streamingDebugModeKey)
        }
    }

    /// Effective streaming-debug flag: requires developer mode.
    var streamingDebugEnabled: Bool {
        developerMode && streamingDebugMode
    }

    /// Recently-used reaction emojis, most-recent first. Drives the quick row
    /// in the message actions overlay.
    private(set) var recentReactions: [String]

    static let defaultReactions = ["👍", "❤️", "😂", "🎉", "😮"]

    /// The five emojis to show in the quick-reaction row: recents first,
    /// topped up with defaults.
    var quickReactions: [String] {
        var result = recentReactions
        for emoji in Self.defaultReactions where result.count < 5 {
            if !result.contains(emoji) { result.append(emoji) }
        }
        return Array(result.prefix(5))
    }

    func addRecentReaction(_ emoji: String) {
        var list = recentReactions.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentReactions = Array(list.prefix(12))
        UserDefaults.standard.set(recentReactions, forKey: Self.recentReactionsKey)
    }

    /// The live FFI runtime. Released (`nil`) while the app is suspended in the
    /// background so its SQLite storage in the shared App Group container is
    /// closed and its file lock freed — otherwise iOS terminates the app at
    /// suspension with `0xdead10cc` ("held a file lock in a shared container").
    /// Rebuilt on foreground in `resumeAfterForegroundActivation`.
    @ObservationIgnored private(set) var client: MarmotClient?
    private let runtimeRootPath: String
    private let runtimeRelayUrls: [String]
    let notifications: AppNotifications
    let toastState = ToastState()
    let navigation = NavigationState()
    private let notificationDriver = NotificationDriver()
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapTaskID = UUID()
    private var foregroundActivationTask: Task<Void, Never>?
    private var nativePushRegistrationTask: Task<Void, Never>?
    private var runtimeSuspensionTask: Task<Void, Never>?
    @ObservationIgnored var profileFetchQueueTask: Task<Void, Never>?
    @ObservationIgnored var queuedProfileFetchIDs: [String] = []
    @ObservationIgnored var scheduledProfileFetchIDs: Set<String> = []
    @ObservationIgnored var activeProfileFetchID: String?
    @ObservationIgnored var profileProjectionCache: [String: ProfileDisplayProjection] = [:]
    @ObservationIgnored var profileProjectionLoadTask: Task<Void, Never>?
    @ObservationIgnored var queuedProfileProjectionLoadIDs: [String] = []
    @ObservationIgnored var scheduledProfileProjectionLoadIDs: Set<String> = []
    @ObservationIgnored var profileProjectionRefreshAfterLoadIDs: Set<String> = []
    @ObservationIgnored var profileProjectionLoadVersions: [String: Int] = [:]
    private var runtimeSuspensionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isForegroundCatchUpRunning = false
    private var isRuntimeSuspending = false
    /// True only while `signOut()` is tearing down the departing account. Set
    /// before any of sign-out's `await` suspension points and cleared once the
    /// account is removed and `accounts` refreshed. `scheduleNativePushRegistrationIfEnabled()`
    /// consults this so a system-driven APNS token arriving mid-sign-out cannot
    /// spawn a fresh registration sync that re-`upsertPushRegistration`s the
    /// account whose registration sign-out just cleared (#320, residual of
    /// #7/#111). MainActor-owned; mutated only on the MainActor.
    private var isSigningOut = false
    private var notificationSubscriptionFailureToastPresented = false
    private(set) var isAppSceneActive = true
    private(set) var runtimeSuspendedForBackground = false
    private(set) var runtimeGeneration = 0
    private(set) var profileRefreshGeneration = 0
    @ObservationIgnored private let suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig

    /// Most recent transient banner. View code reads this via the
    /// `.toastHost()` modifier on the root view.
    var activeToast: Toast? { toastState.activeToast }

    /// A profile to present (set by a scanned QR or an opened deep link).
    /// MainView binds a sheet to this.
    var pendingProfile: ProfileLink? { navigation.pendingProfile }

    /// A chat (group id hex) to navigate to once any presenting sheets close —
    /// set right after creating a chat from the composer or a scanned profile.
    /// ChatsListView observes this to push the conversation.
    var pendingChatId: String? { navigation.pendingChatId }
    var pendingChatAccountRef: String? { navigation.pendingChatAccountRef }
    var pendingChatMessageIdHex: String? { navigation.pendingChatMessageIdHex }
    var visibleChat: VisibleChatRoute? { navigation.visibleChat }
    var telemetryBuildConfig: TelemetryBuildConfig {
        client?.telemetryConfig ?? suspendedRuntimeTelemetryBuildConfig
    }
    var notificationSubscriptionActive: Bool { notificationDriver.isRunning }
    var canRefreshProfiles: Bool {
        isAppSceneActive && !runtimeSuspendedForBackground && !isRuntimeSuspending
    }

    private static let activeAccountKey = "marmot.activeAccountRef"
    private static let developerModeKey = "marmot.developerMode"
    private static let streamingDebugModeKey = "marmot.streamingDebugMode"
    private static let recentReactionsKey = "marmot.recentReactions"
    private static let notificationSubscriptionInitialRetryDelayNanoseconds: UInt64 = 1_000_000_000
    private static let notificationSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 60_000_000_000
    private static let defaultSuspendedRuntimeTelemetryBuildConfig = TelemetryBuildConfig.current()
    static let agentTextStreamQuicBrokerCandidate = "quic://quic-broker.ipf.dev:4450"
    static let agentTextStreamQuicCandidates = [agentTextStreamQuicBrokerCandidate]

    init(
        client: MarmotClient,
        notifications: AppNotifications,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig = AppState.defaultSuspendedRuntimeTelemetryBuildConfig
    ) {
        self.client = client
        self.runtimeRootPath = client.rootPath
        self.runtimeRelayUrls = client.relayUrls
        self.notifications = notifications
        self.suspendedRuntimeTelemetryBuildConfig = suspendedRuntimeTelemetryBuildConfig
        self.activeAccountRef = UserDefaults.standard.string(forKey: Self.activeAccountKey)
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        self.streamingDebugMode = UserDefaults.standard.bool(forKey: Self.streamingDebugModeKey)
        self.recentReactions = UserDefaults.standard.stringArray(forKey: Self.recentReactionsKey)
            ?? Self.defaultReactions
    }

    convenience init(client: MarmotClient) {
        self.init(client: client, notifications: .shared)
    }

    deinit {
        bootstrapTask?.cancel()
        foregroundActivationTask?.cancel()
        nativePushRegistrationTask?.cancel()
        runtimeSuspensionTask?.cancel()
        profileFetchQueueTask?.cancel()
        profileProjectionLoadTask?.cancel()
    }

    func noteProfileRefreshCompleted() {
        profileRefreshGeneration += 1
    }

    /// Production entry point. Builds a keychain-backed client; if secure
    /// storage or a durable on-disk root can't be initialized the app can't run
    /// safely, so we trap with a clear message rather than fall back to insecure
    /// on-disk keys or a temporary directory iOS will silently purge.
    convenience init() {
        do {
            self.init(client: try MarmotClient())
        } catch {
            // Don't interpolate the error: its description can carry internal
            // Keychain/storage details into crash logs (#21). The type alone is
            // enough to triage which failure mode trapped.
            fatalError("Failed to initialize durable Marmot storage (\(type(of: error)))")
        }
    }

    /// Convenience accessor for the underlying FFI handle.
    ///
    /// Non-optional for call-site ergonomics: the runtime is only released
    /// while the app is suspended, when no UI or view-model code runs. If
    /// something does touch it during the foreground transition (before
    /// `resumeAfterForegroundActivation` restores it), it is rebuilt on demand,
    /// reopening on-disk storage. A rebuild failure is the same unrecoverable
    /// Keychain/storage failure the app traps on at launch.
    var marmot: Marmot {
        if let client { return client.marmot }
        do {
            return try runtimeClient().marmot
        } catch {
            // See init(): keep internal Keychain/storage error details out of
            // crash logs (#21); the error type is enough to triage.
            fatalError("Failed to rebuild Keychain-backed Marmot runtime (\(type(of: error)))")
        }
    }

    func currentMarmotClient() throws -> MarmotClient {
        try runtimeClient()
    }

    private func runtimeClient() throws -> MarmotClient {
        if let client { return client }
        let restored = try makeRuntime()
        client = restored
        return restored
    }

    /// Build a fresh runtime from the captured on-disk root and relay set. Used
    /// to restore the runtime after a background suspension released it.
    private func makeRuntime() throws -> MarmotClient {
        try MarmotClient(rootPath: runtimeRootPath, relayUrls: runtimeRelayUrls)
    }

    private func startCurrentRuntime() async throws {
        try await runtimeClient().startRuntime()
    }

    // MARK: - Bootstrap

    /// Brings the runtime online and refreshes the account list. Called once
    /// per app launch.
    @MainActor
    func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let id = UUID()
        bootstrapTaskID = id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
        clearCompletedBootstrapTask(id: id)
    }

    @MainActor
    private func performBootstrap() async {
        do {
            try await startCurrentRuntime()
            noteRuntimeForegroundReadyAfterSuspension()
            try await refreshAccounts()
            if accounts.isEmpty {
                phase = .onboarding
            } else {
                if activeAccountRef == nil
                    || !accounts.contains(where: { $0.label == activeAccountRef }) {
                    activeAccountRef = accounts.first?.label
                }
                phase = .ready
                // Warm the active account's profile (name + avatar) right away
                // so it's visible without waiting for a screen to request it.
                if let activeId = activeAccount?.accountIdHex {
                    warmProfileProjection(forAccountIdHex: activeId, refreshAfterLoad: true)
                }
                startReadyForegroundMaintenance()
            }
        } catch {
            await releaseRuntimeAfterStartupFailure()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Tear down a partially-created runtime after a failed start so the next
    /// Retry rebuilds a fresh one. Shared by the bootstrap and foreground-resume
    /// failure paths: both set `client` to a new instance and then start it, so
    /// both must release that instance (shutdown + `client = nil`) on failure —
    /// otherwise `runtimeClient()` returns the stale, broken client and Retry
    /// re-invokes `startRuntime()` on a runtime whose `start()` already failed.
    private func releaseRuntimeAfterStartupFailure() async {
        stopNotificationSubscription()
        let pushTask = nativePushRegistrationTask
        nativePushRegistrationTask = nil
        pushTask?.cancel()
        await pushTask?.value
        if let client {
            await client.marmot.shutdown()
            self.client = nil
        }
    }

    private func clearCompletedBootstrapTask(id: UUID) {
        guard bootstrapTaskID == id else { return }
        bootstrapTask = nil
    }

    @MainActor
    private func completeOnboardingAfterIdentityActivation() {
        guard phase == .onboarding else { return }
        phase = .ready
        startReadyForegroundMaintenance()
    }

    @MainActor
    private func startReadyForegroundMaintenance() {
        notifications.configure(appState: self)
        startNotificationSubscription()
        scheduleNativePushRegistrationIfEnabled()
    }

    @MainActor
    private func startNotificationSubscription() {
        notificationSubscriptionFailureToastPresented = false
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: Self.notificationSubscriptionInitialRetryDelayNanoseconds,
            maximumRetryDelayNanoseconds: Self.notificationSubscriptionMaximumRetryDelayNanoseconds,
            subscribe: { [weak self] in
                guard let self else { throw CancellationError() }
                let subscription = try await self.marmot.subscribeNotifications()
                return SubscriptionDriver.notifications(subscription)
            },
            present: { [weak self] update in
                guard let self else { return }
                guard await self.canPresentRuntimeNotificationUpdate() else { return }
                let localNotificationsEnabled = await self.localNotificationsEnabledForPresentation(
                    accountRef: update.accountRef
                )
                guard await self.canPresentRuntimeNotificationUpdate() else { return }
                let shouldPresent = await MainActor.run {
                    guard self.canPresentRuntimeNotificationUpdate() else { return false }
                    self.noteNotificationSubscriptionDelivery()
                    return self.shouldPresentLocalNotification(
                        update,
                        localNotificationsEnabled: localNotificationsEnabled
                    )
                }
                guard shouldPresent else { return }
                guard await self.canPresentRuntimeNotificationUpdate() else { return }
                await self.notifications.present(update: update)
            },
            reportError: { [weak self] error in
                guard let self else { return }
                await MainActor.run {
                    self.reportNotificationSubscriptionError(error)
                }
            }
        )
        notificationDriver.start(runner: runner)
    }

    private func stopNotificationSubscription() {
        notificationDriver.stop()
        notificationSubscriptionFailureToastPresented = false
    }

    @MainActor
    func reportNotificationSubscriptionError(_: Error) {
        guard !notificationSubscriptionFailureToastPresented else { return }
        notificationSubscriptionFailureToastPresented = true
        present(
            .error(
                L10n.string("Notifications unavailable"),
                message: L10n.string("We'll keep trying in the background.")
            )
        )
    }

    @MainActor
    func noteNotificationSubscriptionDelivery() {
        notificationSubscriptionFailureToastPresented = false
    }

    @MainActor
    private func shouldPresentLocalNotification(
        _ update: NotificationUpdateFfi,
        localNotificationsEnabled: Bool
    ) -> Bool {
        LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: localNotificationsEnabled,
            appSceneActive: isAppSceneActive,
            updateAccountRef: update.accountRef,
            updateGroupIdHex: update.groupIdHex,
            visibleChat: visibleChat
        )
    }

    @MainActor
    private func canPresentRuntimeNotificationUpdate() -> Bool {
        NotificationPresentationRuntimeGate.canPresent(
            isTaskCancelled: Task.isCancelled,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: client != nil
        )
    }

    @MainActor
    private func localNotificationsEnabledForPresentation(accountRef: String) async -> Bool {
        guard !Task.isCancelled,
              isAppSceneActive,
              !runtimeSuspendedForBackground,
              !isRuntimeSuspending,
              let client
        else { return true }
        return await client.localNotificationsEnabledForPresentation(accountRef: accountRef)
    }

    // MARK: - Notifications

    func notificationSettings(for accountRef: String) -> NotificationSettingsFfi? {
        try? marmot.notificationSettings(accountRef: accountRef)
    }

    func pushRegistration(for accountRef: String) -> PushRegistrationFfi? {
        try? marmot.pushRegistration(accountRef: accountRef)
    }

    @discardableResult
    func setLocalNotificationsEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi {
        guard let accountRef = activeAccountRef else {
            throw NotificationSettingsActionError.noActiveAccount
        }
        if enabled {
            let granted = try await notifications.requestAuthorization()
            guard granted else { throw NotificationSettingsActionError.permissionDenied }
        }
        return try marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: enabled)
    }

    @discardableResult
    func setNativePushEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi {
        guard let accountRef = activeAccountRef else {
            throw NotificationSettingsActionError.noActiveAccount
        }

        if enabled {
            guard NativePushServerConfig.current() != nil else {
                throw NotificationSettingsActionError.nativePushNotConfigured
            }
            let granted = try await notifications.requestAuthorizationAndRegister()
            guard granted else { throw NotificationSettingsActionError.permissionDenied }
            return try await enableNativePush(accountRef: accountRef)
        } else {
            return try await disableNativePush(accountRef: accountRef)
        }
    }

    private func enableNativePush(accountRef: String) async throws -> NotificationSettingsFfi {
        let coordinator = NativePushEnableCoordinator(
            setNativePushEnabled: { [marmot] enabled in
                try await marmot.setNativePushEnabled(accountRef: accountRef, enabled: enabled)
            },
            syncPushRegistration: { [self] in
                _ = try await syncNativePushRegistration(accountRef: accountRef)
            }
        )
        return try await coordinator.enable()
    }

    private func disableNativePush(accountRef: String) async throws -> NotificationSettingsFfi {
        let coordinator = NativePushDisableCoordinator(
            setNativePushEnabled: { [marmot] enabled in
                try await marmot.setNativePushEnabled(accountRef: accountRef, enabled: enabled)
            },
            clearPushRegistration: { [marmot] in
                try await marmot.clearPushRegistration(accountRef: accountRef)
            }
        )
        return try await coordinator.disable()
    }

    private func enableNotificationsByDefault(for accountRef: String) async {
        do {
            let granted = try await notifications.requestAuthorization()
            guard granted else { return }

            _ = try marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: true)

            guard NativePushServerConfig.current() != nil else { return }
            notifications.registerForRemoteNotifications()
            _ = try await enableNativePush(accountRef: accountRef)
        } catch {
            // Notification defaults are best-effort: account activation should
            // still succeed if iOS permission or push registration is blocked.
        }
    }

    /// Signs out of the active account: clears its native push registration
    /// (so the push server stops delivering its notifications to this device)
    /// and disables its `nativePushEnabled` preference, removes the local
    /// account, then switches the active account to the next available local
    /// account (or returns to onboarding when none remain).
    ///
    /// Push cleanup is best-effort — a transient marmot error here must not
    /// block the user from signing out.
    @MainActor
    func signOut() async {
        guard let signingOut = activeAccountRef else { return }
        // Block any APNS-token-driven reschedule for the duration of the
        // teardown. `recordDeviceToken` (MainActor) can land on any of the
        // `await` suspension points below and call
        // `scheduleNativePushRegistrationIfEnabled()`; without this guard that
        // fresh task would re-`upsertPushRegistration` the departing account
        // (still on disk with native push enabled until `setNativePushEnabled`
        // commits, and still in the in-memory `accounts` list until
        // `refreshAccounts`), resurrecting a server-side registration for a
        // signed-out account (#320, residual of #7/#111). The `defer` clears
        // the flag on every exit path, including the early `removeAccount`
        // failure return below.
        isSigningOut = true
        defer { isSigningOut = false }
        await cancelNativePushRegistrationTask()
        try? await marmot.clearPushRegistration(accountRef: signingOut)
        _ = try? await marmot.setNativePushEnabled(accountRef: signingOut, enabled: false)

        do {
            try await marmot.removeAccount(accountRef: signingOut)
        } catch {
            present(.error(L10n.string("Couldn't sign out"), message: error.localizedDescription))
            return
        }

        do {
            try await refreshAccounts()
        } catch {
            accounts.removeAll { $0.label == signingOut }
            present(.error(L10n.string("Couldn't refresh accounts"), message: error.localizedDescription))
        }

        // The departing account is now removed from disk and excluded from the
        // in-memory `accounts` list, so it can no longer be re-registered. Clear
        // the guard before routing so a legitimate reschedule for the *new*
        // active account below is not suppressed (the trailing `defer` then
        // becomes a no-op redo).
        isSigningOut = false
        activeAccountRef = accounts.first?.label
        if activeAccountRef == nil {
            stopNotificationSubscription()
            phase = .onboarding
        } else {
            scheduleNativePushRegistrationIfEnabled()
        }
    }

    @discardableResult
    func syncNativePushRegistration(accountRef: String) async throws -> PushRegistrationFfi {
        guard let config = NativePushServerConfig.current() else {
            throw NotificationSettingsActionError.nativePushNotConfigured
        }
        guard let tokenHex = notifications.apnsTokenHex, !tokenHex.isEmpty else {
            throw NotificationSettingsActionError.missingApnsToken
        }
        return try await marmot.upsertPushRegistration(
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

    func syncNativePushRegistrationIfEnabled() async {
        guard isAppSceneActive,
              !runtimeSuspendedForBackground,
              !isRuntimeSuspending,
              !Task.isCancelled
        else { return }

        let accountRefs = await nativePushEnabledAccountRefs()
        guard !accountRefs.isEmpty,
              NativePushServerConfig.current() != nil
        else { return }

        if NativePushRegistrationPolicy.shouldRequestRemoteToken(
            accountRefs: accountRefs,
            currentToken: notifications.apnsTokenHex
        ) {
            await notifications.registerForRemoteNotificationsIfAuthorized()
        }

        guard notifications.apnsTokenHex?.isEmpty == false else { return }

        var lastError: Error?
        for accountRef in accountRefs {
            guard isAppSceneActive,
                  !runtimeSuspendedForBackground,
                  !isRuntimeSuspending,
                  !Task.isCancelled
            else { return }

            do {
                _ = try await syncNativePushRegistration(accountRef: accountRef)
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
            present(.error(L10n.string("Push registration failed"), message: lastError.localizedDescription))
        }
    }

    func scheduleNativePushRegistrationIfEnabled() {
        guard NativePushRegistrationScheduleGate.canSchedule(
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            isSigningOut: isSigningOut
        ) else { return }
        let previousTask = nativePushRegistrationTask
        previousTask?.cancel()
        nativePushRegistrationTask = Task { [weak self] in
            // Drain the prior (now-cancelled) registration task before starting
            // a fresh sync so overlapping per-account upsertPushRegistration FFI
            // writes cannot run concurrently. The per-account loop only checks
            // Task.isCancelled *between* accounts, so without this await a
            // reschedule (e.g. on token arrival) could issue two concurrent
            // upsertPushRegistration calls. Mirrors cancelNativePushRegistrationTask().
            await previousTask?.value
            guard let self else { return }
            await syncNativePushRegistrationIfEnabled()
        }
    }

    private func cancelNativePushRegistrationTask() async {
        let task = nativePushRegistrationTask
        nativePushRegistrationTask = nil
        task?.cancel()
        await task?.value
    }

    func relayTelemetrySettings() throws -> RelayTelemetrySettingsFfi {
        try marmot.relayTelemetrySettings()
    }

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection {
        try await runtimeClient().privacySecuritySettingsProjection()
    }

    /// Parses markdown off the MainActor for the send path's optimistic record.
    /// Falls back to an empty document if the runtime can't be resolved (e.g.
    /// during a suspend/resume window); the timeline subscription will replace
    /// the optimistic record with the confirmed, fully-parsed one (#226).
    func parseMarkdown(text: String) async -> MarkdownDocumentFfi {
        guard let client = try? runtimeClient() else { return .emptyDocument }
        return await client.parseMarkdown(text: text)
    }

    @MainActor
    @discardableResult
    func setRelayTelemetryExportEnabled(_ enabled: Bool) async throws -> RelayTelemetrySettingsFfi {
        if enabled && !telemetryBuildConfig.telemetryCredentialsAvailable {
            throw TelemetrySettingsActionError.telemetryNotConfigured
        }
        let client = try runtimeClient()
        if enabled {
            try await client.configureTelemetryRuntime()
        }
        let current = try await client.relayTelemetrySettings()
        return try await client.marmot.setRelayTelemetrySettings(
            settings: RelayTelemetrySettingsFfi(
                exportEnabled: enabled,
                exportIntervalSeconds: current.exportIntervalSeconds
            )
        )
    }

    func auditLogSettings() throws -> AuditLogSettingsFfi {
        try marmot.auditLogSettings()
    }

    @MainActor
    @discardableResult
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi {
        try await marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: enabled))
    }

    func auditLogFiles() throws -> [AuditLogFileFfi] {
        try marmot.auditLogFiles()
    }

    func auditLogFileRows() async throws -> [AuditFileRow] {
        try await runtimeClient().auditFileRows()
    }

    @MainActor
    func deleteAllAuditLogFiles() async throws {
        guard phase == .ready else { return }
        let client = try runtimeClient()
        let files = try await client.auditLogFiles()
        for file in files {
            _ = try await client.marmot.deleteAuditLogFile(path: file.path)
        }
    }

    func catchUpAfterForegroundActivation() async {
        guard ForegroundNotificationSyncPolicy.shouldCatchUp(
            appPhase: phase,
            isCatchUpRunning: isForegroundCatchUpRunning,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending
        ) else { return }

        isForegroundCatchUpRunning = true
        defer { isForegroundCatchUpRunning = false }

        do {
            try await marmot.catchUpAccounts()
        } catch {
            // Foreground catch-up is a best-effort safety net. The live
            // subscription and NSE path continue to handle notification flow.
        }
    }

    func setAppSceneActive(_ active: Bool) {
        isAppSceneActive = active
        if !active {
            foregroundActivationTask?.cancel()
            nativePushRegistrationTask?.cancel()
        }
    }

    @discardableResult
    func startForegroundActivation() -> Task<Void, Never> {
        isAppSceneActive = true
        foregroundActivationTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await resumeAfterForegroundActivation()
        }
        foregroundActivationTask = task
        return task
    }

    @discardableResult
    func startRuntimeSuspension() -> Task<Void, Never> {
        isAppSceneActive = false
        foregroundActivationTask?.cancel()
        nativePushRegistrationTask?.cancel()
        if let runtimeSuspensionTask {
            return runtimeSuspensionTask
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await prepareForBackgroundSuspension()
        }
        runtimeSuspensionTask = task
        return task
    }

    func prepareForBackgroundSuspension() async {
        defer { runtimeSuspensionTask = nil }
        await cancelForegroundMaintenance()
        // `isAppSceneActive` is owned by the synchronous scene-phase entry
        // points (`startRuntimeSuspension` / `startForegroundActivation` /
        // `setAppSceneActive`), which run in true scene-delivery order. After
        // the `await` above a racing foreground activation may have flipped the
        // scene back to active. Re-check the authoritative flag before the
        // irreversible teardown: suspending now would strand the app
        // foregrounded with `client == nil` and nothing to re-trigger resume
        // (#222). Hand back to a fresh foreground activation instead.
        guard !isAppSceneActive else {
            startForegroundActivation()
            return
        }
        guard phase == .ready,
              !runtimeSuspendedForBackground,
              !isRuntimeSuspending
        else { return }

        isRuntimeSuspending = true
        defer { finishRuntimeSuspensionWait() }
        stopNotificationSubscription()
        await marmot.shutdown()
        // Release the FFI handle so Rust drops the runtime and closes its
        // SQLite storage in the shared App Group container. Holding the handle
        // alive across suspension (only swapping it on resume) keeps that
        // file lock held, which is what iOS kills the app for with
        // `0xdead10cc`. Rebuilt in `resumeAfterForegroundActivation`.
        client = nil
        runtimeSuspendedForBackground = true
    }

    func resumeAfterForegroundActivation() async {
        await waitForRuntimeSuspensionToFinish()
        guard phase == .ready, !Task.isCancelled else { return }

        if runtimeSuspendedForBackground {
            do {
                let restored = try makeRuntime()
                client = restored
                try await restored.startRuntime()
                noteRuntimeForegroundReadyAfterSuspension()
                startNotificationSubscription()
            } catch {
                // Release the partial runtime before showing the failure screen
                // so Retry → bootstrap() → runtimeClient() rebuilds a fresh
                // runtime instead of reusing this instance whose start() failed.
                await releaseRuntimeAfterStartupFailure()
                phase = .failed(error.localizedDescription)
                return
            }
        }

        guard isAppSceneActive, !Task.isCancelled else { return }
        await catchUpAfterForegroundActivation()
        guard isAppSceneActive, !Task.isCancelled else { return }
        scheduleNativePushRegistrationIfEnabled()
        resumeProfileFetchQueueIfNeeded()
    }

    private func noteRuntimeForegroundReadyAfterSuspension() {
        guard runtimeSuspendedForBackground || isRuntimeSuspending else { return }
        runtimeSuspendedForBackground = false
        finishRuntimeSuspensionWait()
        runtimeGeneration += 1
    }

    private func waitForRuntimeSuspensionToFinish() async {
        guard isRuntimeSuspending else { return }
        let waiterID = UUID()

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard isRuntimeSuspending, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                runtimeSuspensionWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeRuntimeSuspensionWaiter(id: waiterID)
            }
        }
    }

    private func finishRuntimeSuspensionWait() {
        isRuntimeSuspending = false
        let waiters = Array(runtimeSuspensionWaiters.values)
        runtimeSuspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeRuntimeSuspensionWaiter(id: UUID) {
        runtimeSuspensionWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelForegroundMaintenance() async {
        let foregroundTask = foregroundActivationTask
        foregroundActivationTask = nil
        foregroundTask?.cancel()

        let pushTask = nativePushRegistrationTask
        nativePushRegistrationTask = nil
        pushTask?.cancel()

        let profileTask = cancelProfileFetchQueue()

        await foregroundTask?.value
        await pushTask?.value
        await profileTask?.value
    }

    private func nativePushEnabledAccountRefs() async -> [String] {
        let accountRefs = accounts.map(\.label)
        do {
            let client = try runtimeClient()
            return await client.nativePushEnabledAccountRefs(accountRefs: accountRefs)
        } catch {
            fatalError("Failed to rebuild Keychain-backed Marmot runtime (\(type(of: error)))")
        }
    }

    @MainActor
    private func refreshAccounts() async throws {
        accounts = try await runtimeClient().listAccounts()
        updateProfileProjectionLocalAccountLabels()
        warmLocalAccountProfileProjections()
    }

    // MARK: - Identity management

    /// Generate a fresh Nostr identity. On success the new account becomes active.
    @MainActor
    @discardableResult
    func createIdentity() async throws -> AccountSummaryFfi {
        let relays = MarmotClient.seedRelays
        let summary = try await marmot.createIdentity(
            defaultRelays: relays,
            bootstrapRelays: relays
        )
        try await refreshAccounts()
        activeAccountRef = summary.label
        completeOnboardingAfterIdentityActivation()
        await enableNotificationsByDefault(for: summary.label)
        return summary
    }

    /// Import an existing local-signing identity (nsec).
    @MainActor
    @discardableResult
    func importIdentity(_ identity: String) async throws -> AccountSummaryFfi {
        let relays = MarmotClient.seedRelays
        let summary = try await marmot.login(
            identity: identity,
            defaultRelays: relays,
            bootstrapRelays: relays
        )
        try await refreshAccounts()
        activeAccountRef = summary.label
        completeOnboardingAfterIdentityActivation()
        await enableNotificationsByDefault(for: summary.label)
        return summary
    }

    var activeAccount: AccountSummaryFfi? {
        guard let ref = activeAccountRef else { return nil }
        return accounts.first { $0.label == ref }
    }

    /// Reads the published account relay-list projection off the MainActor.
    /// `Marmot.accountRelayLists` is synchronous FFI backed by local storage, so
    /// MainActor-bound callers (profile publish / profile refresh) must await the
    /// `MarmotClient.accountRelayLists` wrapper rather than calling the generated
    /// binding inline (#318). Mirrors the #247/#317 offload approach.
    func relayLists(for accountRef: String) async -> AccountRelayListsFfi? {
        try? await currentMarmotClient().accountRelayLists(accountRef: accountRef)
    }

    func relayPublishRelays(for accountRef: String) async -> [String] {
        guard let lists = await relayLists(for: accountRef) else { return MarmotClient.seedRelays }
        let relays = RelaySettings.editableRelays(from: lists)
        return relays.isEmpty ? MarmotClient.seedRelays : relays
    }

    func relayBootstrapRelays(for accountRef: String) async -> [String] {
        guard let lists = await relayLists(for: accountRef) else { return MarmotClient.seedRelays }
        return RelaySettings.bootstrapRelays(from: lists)
    }

    @discardableResult
    func startAgentTextStream(
        accountRef: String,
        groupIdHex: String,
        streamIdHex: String? = nil
    ) async throws -> AgentStreamStartFfi {
        try await marmot.startAgentTextStream(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            streamIdHex: streamIdHex,
            quicCandidates: Self.agentTextStreamQuicCandidates
        )
    }

    #if DEBUG
    /// Drives the suspend/resume lifecycle tasks to quiescence so tests can
    /// drive the real scene-phase entry points (`startRuntimeSuspension` /
    /// `startForegroundActivation`) and then await the terminal state. A
    /// suspension that re-checks the scene and reschedules a resume (#222)
    /// chains a fresh `foregroundActivationTask`; resume never reschedules a
    /// suspension, so awaiting suspension, then the (possibly rescheduled)
    /// foreground activation, then native-push registration drains the chain.
    @MainActor
    func drainRuntimeLifecycleTasksForTesting() async {
        await runtimeSuspensionTask?.value
        await foregroundActivationTask?.value
        await nativePushRegistrationTask?.value
    }

    /// Exposes the sign-out teardown guard (#320) so tests can assert it is
    /// raised only during `signOut()` and cleared before the function returns
    /// (so a legitimate post-sign-out reschedule is not suppressed).
    @MainActor
    var isSigningOutForTesting: Bool { isSigningOut }
    #endif
}
