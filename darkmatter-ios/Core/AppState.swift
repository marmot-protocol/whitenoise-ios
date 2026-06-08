import Foundation
import Observation
import MarmotKit

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
    let profileCache = ProfileCache()
    private let notificationDriver = NotificationDriver()
    private var foregroundActivationTask: Task<Void, Never>?
    private var nativePushRegistrationTask: Task<Void, Never>?
    private var runtimeSuspensionTask: Task<Void, Never>?
    @ObservationIgnored var profileFetchQueueTask: Task<Void, Never>?
    @ObservationIgnored var queuedProfileFetchIDs: [String] = []
    @ObservationIgnored var scheduledProfileFetchIDs: Set<String> = []
    @ObservationIgnored var activeProfileFetchID: String?
    private var runtimeSuspensionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isForegroundCatchUpRunning = false
    private var isRuntimeSuspending = false
    private(set) var isAppSceneActive = true
    private(set) var runtimeSuspendedForBackground = false
    private(set) var runtimeGeneration = 0

    /// Cache of best-known display names keyed by account id hex. Derived
    /// from `profiles` when available. Read-only from view code.
    var displayNames: [String: String] { profileCache.displayNames }

    /// Cache of full Nostr kind:0 profiles keyed by account id hex. Populated
    /// on demand via `profile(forAccountIdHex:)`. Read-only from view code.
    var profiles: [String: UserProfileMetadataFfi] { profileCache.profiles }

    /// Cache of npub (bech32) forms keyed by account id hex. Conversion is
    /// deterministic and offline, so these never go stale.
    var npubs: [String: String] { profileCache.npubs }

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
        client?.telemetryConfig ?? TelemetryBuildConfig.current()
    }
    var notificationSubscriptionActive: Bool { notificationDriver.isRunning }

    private static let activeAccountKey = "marmot.activeAccountRef"
    private static let developerModeKey = "marmot.developerMode"
    private static let recentReactionsKey = "marmot.recentReactions"
    private static let notificationSubscriptionInitialRetryDelayNanoseconds: UInt64 = 1_000_000_000
    private static let notificationSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 60_000_000_000
    static let agentTextStreamQuicBrokerCandidate = "quic://quic-broker.ipf.dev:4450"
    static let agentTextStreamQuicCandidates = [agentTextStreamQuicBrokerCandidate]

    init(client: MarmotClient, notifications: AppNotifications) {
        self.client = client
        self.runtimeRootPath = client.rootPath
        self.runtimeRelayUrls = client.relayUrls
        self.notifications = notifications
        self.activeAccountRef = UserDefaults.standard.string(forKey: Self.activeAccountKey)
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        self.recentReactions = UserDefaults.standard.stringArray(forKey: Self.recentReactionsKey)
            ?? Self.defaultReactions
    }

    convenience init(client: MarmotClient) {
        self.init(client: client, notifications: .shared)
    }

    /// Production entry point. Builds a keychain-backed client; if secure
    /// storage or a durable on-disk root can't be initialized the app can't run
    /// safely, so we trap with a clear message rather than fall back to insecure
    /// on-disk keys or a temporary directory iOS will silently purge.
    convenience init() {
        do {
            self.init(client: try MarmotClient())
        } catch {
            fatalError("Failed to initialize durable Marmot storage: \(error)")
        }
    }

    deinit {
        profileFetchQueueTask?.cancel()
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
            fatalError("Failed to rebuild Keychain-backed Marmot runtime: \(error)")
        }
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
        do {
            try await startCurrentRuntime()
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
                    _ = profile(forAccountIdHex: activeId)
                }
                startReadyForegroundMaintenance()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
        let runner = NotificationSubscriptionRunner(
            initialRetryDelayNanoseconds: Self.notificationSubscriptionInitialRetryDelayNanoseconds,
            maximumRetryDelayNanoseconds: Self.notificationSubscriptionMaximumRetryDelayNanoseconds,
            subscribe: { [weak self] in
                guard let self else { throw CancellationError() }
                let subscription = try await self.marmot.subscribeNotifications()
                return SubscriptionDriver.notifications(subscription)
            },
            present: { [weak self] update in
                guard let self, self.shouldPresentLocalNotification(update) else { return }
                await self.notifications.present(update: update)
            },
            reportError: { [weak self] error in
                guard let self else { return }
                await MainActor.run {
                    self.present(
                        .error(
                            L10n.string("Notifications unavailable"),
                            message: error.localizedDescription
                        )
                    )
                }
            }
        )
        notificationDriver.start(runner: runner)
    }

    private func stopNotificationSubscription() {
        notificationDriver.stop()
    }

    private func shouldPresentLocalNotification(_ update: NotificationUpdateFfi) -> Bool {
        LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: (try? marmot.notificationSettings(
                accountRef: update.accountRef
            ).localNotificationsEnabled) == true,
            appSceneActive: isAppSceneActive,
            updateAccountRef: update.accountRef,
            updateGroupIdHex: update.groupIdHex,
            visibleChat: visibleChat
        )
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
            let settings = try await marmot.setNativePushEnabled(accountRef: accountRef, enabled: true)
            do {
                try await syncNativePushRegistration(accountRef: accountRef)
            } catch NotificationSettingsActionError.missingApnsToken {
                // APNS token delivery is asynchronous; the app delegate will
                // retry registration as soon as iOS provides the token.
            }
            return settings
        } else {
            try await marmot.clearPushRegistration(accountRef: accountRef)
            return try await marmot.setNativePushEnabled(accountRef: accountRef, enabled: false)
        }
    }

    private func enableNotificationsByDefault(for accountRef: String) async {
        do {
            let granted = try await notifications.requestAuthorization()
            guard granted else { return }

            _ = try marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: true)

            guard NativePushServerConfig.current() != nil else { return }
            notifications.registerForRemoteNotifications()
            _ = try await marmot.setNativePushEnabled(accountRef: accountRef, enabled: true)

            do {
                _ = try await syncNativePushRegistration(accountRef: accountRef)
            } catch NotificationSettingsActionError.missingApnsToken {
                // APNS token delivery is asynchronous; the app delegate will
                // retry registration as soon as iOS provides the token.
            }
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
        cancelProfileFetchQueue()
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

        activeAccountRef = accounts.first?.label
        if activeAccountRef == nil {
            stopNotificationSubscription()
            nativePushRegistrationTask?.cancel()
            nativePushRegistrationTask = nil
            phase = .onboarding
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
            relayHint: config.relayHint
        )
    }

    func syncNativePushRegistrationIfEnabled() async {
        guard isAppSceneActive,
              !runtimeSuspendedForBackground,
              !isRuntimeSuspending,
              !Task.isCancelled
        else { return }

        let accountRefs = nativePushEnabledAccountRefs()
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
            } catch NotificationSettingsActionError.missingApnsToken {
                return
            } catch {
                lastError = error
            }
        }

        if let lastError {
            present(.error(L10n.string("Push registration failed"), message: lastError.localizedDescription))
        }
    }

    func scheduleNativePushRegistrationIfEnabled() {
        guard isAppSceneActive,
              !runtimeSuspendedForBackground,
              !isRuntimeSuspending
        else { return }
        guard !nativePushEnabledAccountRefs().isEmpty else { return }
        nativePushRegistrationTask?.cancel()
        nativePushRegistrationTask = Task { [weak self] in
            guard let self else { return }
            await syncNativePushRegistrationIfEnabled()
        }
    }

    func relayTelemetrySettings() throws -> RelayTelemetrySettingsFfi {
        try marmot.relayTelemetrySettings()
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
        let current = try client.marmot.relayTelemetrySettings()
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
        let settings = try marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: enabled))
        try await restartRuntimeForAuditLogSettingsChange()
        return settings
    }

    func auditLogFiles() throws -> [AuditLogFileFfi] {
        try marmot.auditLogFiles()
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
            guard isAppSceneActive, !Task.isCancelled else { return }
            await syncNativePushRegistrationIfEnabled()
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

    func startForegroundActivation() {
        isAppSceneActive = true
        foregroundActivationTask?.cancel()
        foregroundActivationTask = Task { [weak self] in
            guard let self else { return }
            await resumeAfterForegroundActivation()
        }
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
        isAppSceneActive = false
        cancelProfileFetchQueue()
        await cancelForegroundMaintenance()
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
        isAppSceneActive = true
        await waitForRuntimeSuspensionToFinish()
        guard phase == .ready, !Task.isCancelled else { return }

        if runtimeSuspendedForBackground {
            do {
                let restored = try makeRuntime()
                client = restored
                try await restored.startRuntime()
                runtimeSuspendedForBackground = false
                runtimeGeneration += 1
                startNotificationSubscription()
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }

        guard isAppSceneActive, !Task.isCancelled else { return }
        await catchUpAfterForegroundActivation()
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

    @MainActor
    private func restartRuntimeForAuditLogSettingsChange() async throws {
        guard phase == .ready else { return }
        await cancelForegroundMaintenance()
        isRuntimeSuspending = true
        defer { finishRuntimeSuspensionWait() }

        stopNotificationSubscription()
        await marmot.shutdown()
        client = nil

        do {
            let restored = try makeRuntime()
            client = restored
            try await restored.startRuntime()
            runtimeSuspendedForBackground = false
            runtimeGeneration += 1
            try await refreshAccounts()
            if isAppSceneActive {
                startNotificationSubscription()
                scheduleNativePushRegistrationIfEnabled()
            }
        } catch {
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    private func cancelForegroundMaintenance() async {
        let foregroundTask = foregroundActivationTask
        foregroundActivationTask = nil
        foregroundTask?.cancel()

        let pushTask = nativePushRegistrationTask
        nativePushRegistrationTask = nil
        pushTask?.cancel()

        await foregroundTask?.value
        await pushTask?.value
    }

    private func nativePushEnabledAccountRefs() -> [String] {
        NativePushRegistrationPolicy.enabledAccountRefs(accounts: accounts) { accountRef in
            try? marmot.notificationSettings(accountRef: accountRef)
        }
    }

    @MainActor
    private func refreshAccounts() async throws {
        let listed = try await Task.detached { [marmot] in
            try marmot.listAccounts()
        }.value
        accounts = listed
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

    func relayLists(for accountRef: String) -> AccountRelayListsFfi? {
        try? marmot.accountRelayLists(accountRef: accountRef)
    }

    func relayPublishRelays(for accountRef: String) -> [String] {
        guard let lists = relayLists(for: accountRef) else { return MarmotClient.seedRelays }
        let relays = RelaySettings.editableRelays(from: lists)
        return relays.isEmpty ? MarmotClient.seedRelays : relays
    }

    func relayBootstrapRelays(for accountRef: String) -> [String] {
        guard let lists = relayLists(for: accountRef) else { return MarmotClient.seedRelays }
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
}
