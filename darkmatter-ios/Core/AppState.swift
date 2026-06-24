import Foundation
import Observation
import MarmotKit

nonisolated enum ForegroundRuntimeWorkGate {
    static func canUseLocalForegroundWork(
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool,
        hasRuntimeClient: Bool
    ) -> Bool {
        isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
            && hasRuntimeClient
    }

    static func canUseForegroundWork(
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool
    ) -> Bool {
        isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
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

    /// Phases that own a live, started Marmot runtime (its SQLite store open in
    /// the shared App Group container). Both must release that runtime on
    /// background suspension and rebuild it on foreground resume, otherwise the
    /// held file lock risks a `0xdead10cc` watchdog kill (#338). `performBootstrap`
    /// starts the runtime *before* checking for accounts, so `.onboarding` carries
    /// a live runtime exactly like `.ready` does — the suspend/resume machinery
    /// must treat them the same. Maintenance that needs an active account
    /// (notification subscription, push registration) stays gated on `.ready`.
    private var phaseOwnsLiveRuntime: Bool {
        phase == .ready || phase == .onboarding
    }

    /// Account list + active selection. Owned by `AccountStore`; these forwarders
    /// keep the `appState.accounts` / `activeAccountRef` / `activeAccount` call
    /// sites and SwiftUI observation unchanged. AppState still drives the Marmot
    /// account refresh and the identity lifecycle (create / import / sign-out).
    @ObservationIgnored let accountStore = AccountStore()
    var accounts: [AccountSummaryFfi] { accountStore.accounts }

    /// Per-account unread totals (account-switcher badges). Owned by
    /// `AccountUnreadStore`; this read-only forwarder keeps the
    /// `appState.accountUnreadSummariesByAccountId` call sites and SwiftUI
    /// observation of the badges unchanged.
    @ObservationIgnored let accountUnreadStore = AccountUnreadStore()
    var accountUnreadSummariesByAccountId: [String: AccountUnreadFfi] {
        accountUnreadStore.byAccountId
    }

    /// The account whose chats / messages are currently displayed.
    /// `nil` only between bootstrap and onboarding completion. Backed by
    /// `AccountStore` (which persists it to UserDefaults).
    var activeAccountRef: String? {
        get { accountStore.activeAccountRef }
        set { accountStore.activeAccountRef = newValue }
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
    @ObservationIgnored let notificationCoordinator = NotificationCoordinator()
    let toastState = ToastState()
    let navigation = NavigationState()
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapTaskID = UUID()
    private var foregroundActivationTask: Task<Void, Never>?
    private var runtimeSuspensionTask: Task<Void, Never>?
    /// Profile projection cache + hydration/refresh queues. `profileRefreshGeneration`
    /// stays on AppState (below) as the observed token; the store reads/bumps it
    /// through its back-reference so SwiftUI observation is unchanged.
    @ObservationIgnored let profileStore = ProfileStore()
    private var runtimeSuspensionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isRuntimeSuspending = false
    /// True only while `signOut()` is tearing down the departing account. Set
    /// before any of sign-out's `await` suspension points and cleared once the
    /// account is removed and `accounts` refreshed. `scheduleNativePushRegistrationIfEnabled()`
    /// consults this so a system-driven APNS token arriving mid-sign-out cannot
    /// spawn a fresh registration sync that re-`upsertPushRegistration`s the
    /// account whose registration sign-out just cleared (#320, residual of
    /// #7/#111). MainActor-owned; mutated only on the MainActor.
    private var isSigningOut = false
    private(set) var isAppSceneActive = true
    private(set) var runtimeSuspendedForBackground = false
    /// True while the runtime is being (re)started after a background
    /// suspension. During this window the account worker is still hydrating and
    /// running its initial relay catch-up, so live reads (timeline tail, group
    /// roster) are briefly blocked. Conversation chrome surfaces a "Connecting…"
    /// status off this flag instead of appearing frozen. MainActor-owned.
    private(set) var isRuntimeWarmingUp = false
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
    var notificationSubscriptionActive: Bool { notificationCoordinator.notificationSubscriptionActive }
    var canRefreshProfiles: Bool {
        isAppSceneActive && !runtimeSuspendedForBackground && !isRuntimeSuspending
    }
    var canUseRuntimeForLocalForegroundWork: Bool {
        ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: client != nil
        )
    }
    var canUseRuntimeForForegroundWork: Bool {
        ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending
        )
    }

    private static let developerModeKey = "marmot.developerMode"
    private static let streamingDebugModeKey = "marmot.streamingDebugMode"
    private static let recentReactionsKey = "marmot.recentReactions"
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
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        self.streamingDebugMode = UserDefaults.standard.bool(forKey: Self.streamingDebugModeKey)
        self.recentReactions = UserDefaults.standard.stringArray(forKey: Self.recentReactionsKey)
            ?? Self.defaultReactions
        self.profileStore.appState = self
    }

    convenience init(client: MarmotClient) {
        self.init(client: client, notifications: .shared)
    }

    deinit {
        bootstrapTask?.cancel()
        foregroundActivationTask?.cancel()
        runtimeSuspensionTask?.cancel()
        // ProfileStore cancels its own tasks in its deinit.
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
    /// AppState-internal seam only: lifecycle/bootstrap, runtime suspend/resume,
    /// and the notification subscription legitimately need the raw handle. Feature
    /// code (views / view-models / stores) must NOT use this — it goes through
    /// `currentMarmotClient()` and the `MarmotClient` wrappers (the one seam),
    /// enforced by `MarmotHandleLockdownTests` (#395).
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
        notificationCoordinator.stopNotificationSubscription()
        await notificationCoordinator.cancelNativePushRegistrationTask()
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
    private func completeOnboardingAfterIdentityActivation(scheduleNativePushRegistration: Bool = true) {
        guard phase == .onboarding else { return }
        phase = .ready
        startReadyForegroundMaintenance(scheduleNativePushRegistration: scheduleNativePushRegistration)
    }

    @MainActor
    private func startReadyForegroundMaintenance(scheduleNativePushRegistration: Bool = true) {
        notificationCoordinator.startReadyForegroundMaintenance(
            host: self,
            scheduleNativePushRegistration: scheduleNativePushRegistration
        )
    }

    @MainActor
    private func startNotificationSubscription() {
        notificationCoordinator.startNotificationSubscription(host: self)
    }

    private func stopNotificationSubscription() {
        notificationCoordinator.stopNotificationSubscription()
    }

    @MainActor
    func reportNotificationSubscriptionError(_ error: Error) {
        notificationCoordinator.reportNotificationSubscriptionError(error, host: self)
    }

    @MainActor
    func noteNotificationSubscriptionDelivery() {
        notificationCoordinator.noteNotificationSubscriptionDelivery()
    }

    /// Returns the already-live foreground runtime for settings reads, or nil
    /// while the app is inactive/suspending/suspended. Settings reload tasks can
    /// resume during the background transition; using this helper avoids the
    /// rebuilding `marmot` / `runtimeClient()` accessors so they cannot re-open
    /// the App Group SQLite store after suspension deliberately released it.
    private func foregroundSettingsReadClient() -> MarmotClient? {
        let liveClient = client
        guard SettingsReadRuntimeGate.canRead(
            isTaskCancelled: Task.isCancelled,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: liveClient != nil
        ), let liveClient
        else { return nil }
        return liveClient
    }

    // MARK: - Notifications

    func notificationSettings(for accountRef: String) async -> NotificationSettingsFfi? {
        await notificationCoordinator.notificationSettings(for: accountRef, host: self)
    }

    func pushRegistration(for accountRef: String) async -> PushRegistrationFfi? {
        await notificationCoordinator.pushRegistration(for: accountRef, host: self)
    }

    @discardableResult
    func setLocalNotificationsEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi {
        try await notificationCoordinator.setLocalNotificationsEnabled(enabled, host: self)
    }

    @discardableResult
    func setNativePushEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi {
        try await notificationCoordinator.setNativePushEnabled(enabled, host: self)
    }

    private func enableNotificationsByDefault(for accountRef: String) async {
        await notificationCoordinator.enableNotificationsByDefault(for: accountRef, host: self)
    }

    /// Switches the active account, signing it back in first when it was
    /// locally signed out without wiping.
    @MainActor
    func activateAccount(_ accountRef: String) async {
        guard accountRef != activeAccountRef else { return }
        guard let account = accounts.first(where: { $0.label == accountRef }) else { return }

        if account.signedOut {
            do {
                _ = try await marmot.signInAccount(accountRef: accountRef)
                try await refreshAccounts()
            } catch {
                present(.error(L10n.string("Couldn't sign in"), message: error.localizedDescription))
                return
            }
        }

        activeAccountRef = accountRef
        scheduleNativePushRegistrationIfEnabled()
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
        // the flag on every exit path, including the early wipe failure return
        // below.
        isSigningOut = true
        defer { isSigningOut = false }
        await notificationCoordinator.cancelNativePushRegistrationTask()
        try? await marmot.clearPushRegistration(accountRef: signingOut)
        _ = try? await marmot.setNativePushEnabled(accountRef: signingOut, enabled: false)

        do {
            let outcome = try await marmot.signOutAndWipe(accountRef: signingOut)
            guard outcome.localCleanup.completed else {
                let message = outcome.localCleanup.reason
                    ?? L10n.string("Local account cleanup did not finish.")
                present(.error(L10n.string("Couldn't sign out"), message: message))
                return
            }
        } catch {
            present(.error(L10n.string("Couldn't sign out"), message: error.localizedDescription))
            return
        }

        do {
            try await refreshAccounts()
        } catch {
            accountStore.accounts.removeAll { $0.label == signingOut }
            accountUnreadStore.pruneToCurrentAccounts(accounts)
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
            // Last account signed out: tear the profile-projection state back
            // down to empty so cached peer data (#366), the per-account version
            // map (#353), and their sibling queues do not survive a full sign-out
            // into onboarding. `cancelProfileFetchQueue()` cancels in-flight work
            // and clears the sibling queues but deliberately preserves the
            // monotonic version map (see its comment). The version-map wipe is the
            // ABA barrier for any suspended profile reload: when it resumes, the
            // stale token check fails before it can re-bump the gone account id or
            // apply a projection back into the cache. This reclaims the accumulated
            // entries.
            cancelProfileFetchQueue()
            profileStore.clearForSignOut()
            stopNotificationSubscription()
            phase = .onboarding
        } else {
            scheduleNativePushRegistrationIfEnabled()
        }
    }

    @discardableResult
    func syncNativePushRegistration(accountRef: String) async throws -> PushRegistrationFfi {
        try await notificationCoordinator.syncNativePushRegistration(accountRef: accountRef, host: self)
    }

    func syncNativePushRegistrationIfEnabled() async {
        await notificationCoordinator.syncNativePushRegistrationIfEnabled(host: self)
    }

    func scheduleNativePushRegistrationIfEnabled() {
        notificationCoordinator.scheduleNativePushRegistrationIfEnabled(host: self)
    }

    func relayTelemetrySettings() async throws -> RelayTelemetrySettingsFfi? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.relayTelemetrySettings()
    }

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.privacySecuritySettingsProjection()
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

    func auditLogSettings() async throws -> AuditLogSettingsFfi? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditLogSettings()
    }

    @MainActor
    @discardableResult
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi {
        try await marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: enabled))
    }

    func auditLogFiles() async throws -> [AuditLogFileFfi]? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditLogFiles()
    }

    func auditLogFileRows() async throws -> [AuditFileRow]? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditFileRows()
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
        await notificationCoordinator.catchUpAfterForegroundActivation(host: self)
    }

    func setAppSceneActive(_ active: Bool) {
        isAppSceneActive = active
        if !active {
            foregroundActivationTask?.cancel()
            notificationCoordinator.setAppSceneActive(active)
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
        notificationCoordinator.setAppSceneActive(false)
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
        guard phaseOwnsLiveRuntime,
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
        guard phaseOwnsLiveRuntime, !Task.isCancelled else { return }

        if runtimeSuspendedForBackground {
            isRuntimeWarmingUp = true
            // Cleared on both the success and failure exits of the restart so a
            // failed resume doesn't strand the "Connecting…" chrome on.
            defer { isRuntimeWarmingUp = false }
            do {
                let restored = try makeRuntime()
                client = restored
                try await restored.startRuntime()
                noteRuntimeForegroundReadyAfterSuspension()
                // The notification subscription needs an active account, so it
                // only belongs to `.ready`. An `.onboarding` resume rebuilds the
                // runtime (releasing the suspended App Group SQLite lock) but
                // mirrors `performBootstrap`'s onboarding branch, which starts no
                // subscription. The subscription begins when onboarding completes
                // via `startReadyForegroundMaintenance()` (#338).
                if phase == .ready {
                    startNotificationSubscription()
                }
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
        // The remaining maintenance is account-scoped and no-ops safely in
        // `.onboarding`: `catchUpAfterForegroundActivation` is `.ready`-gated by
        // `ForegroundNotificationSyncPolicy`, and the push-registration / profile
        // queue paths find no accounts to act on while onboarding.
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

        notificationCoordinator.cancelNativePushRegistrationTaskWithoutAwaiting()
        let profileTask = cancelProfileFetchQueue()

        await foregroundTask?.value
        await notificationCoordinator.cancelNativePushRegistrationTask()
        await profileTask?.value
    }

    static func nativePushEnabledAccountRefs(
        accountRefs: [String],
        runtimeClient: () throws -> MarmotClient
    ) async -> [String] {
        await NotificationCoordinator.nativePushEnabledAccountRefs(
            accountRefs: accountRefs,
            runtimeClient: runtimeClient
        )
    }

    @MainActor
    private func refreshAccounts() async throws {
        accountStore.accounts = try await runtimeClient().listAccounts()
        await refreshAccountUnreadSummaries()
        updateProfileProjectionLocalAccountLabels()
        warmLocalAccountProfileProjections()
    }

    /// Fetches the durable unread aggregate (client access is AppState's domain)
    /// and feeds it to the store; on failure prunes stale entries.
    @MainActor
    func refreshAccountUnreadSummaries() async {
        guard !accounts.isEmpty else {
            accountUnreadStore.refreshed(from: [], accounts: [])
            return
        }
        do {
            let summaries = try await runtimeClient().accountUnreadSummary()
            accountUnreadStore.refreshed(from: summaries, accounts: accounts)
        } catch {
            accountUnreadStore.pruneToCurrentAccounts(accounts)
        }
    }

    @MainActor
    func accountUnreadSummary(forAccountIdHex accountIdHex: String) -> AccountUnreadFfi? {
        accountUnreadStore.summary(forAccountIdHex: accountIdHex)
    }

    @MainActor
    func updateAccountUnreadSummary(
        accountIdHex: String,
        chatListRows: [ChatListRowFfi]
    ) {
        accountUnreadStore.update(accountIdHex: accountIdHex, chatListRows: chatListRows, accounts: accounts)
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
        completeOnboardingAfterIdentityActivation(scheduleNativePushRegistration: false)
        await enableNotificationsByDefault(for: summary.label)
        scheduleNativePushRegistrationIfEnabled()
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
        completeOnboardingAfterIdentityActivation(scheduleNativePushRegistration: false)
        await enableNotificationsByDefault(for: summary.label)
        scheduleNativePushRegistrationIfEnabled()
        return summary
    }

    var activeAccount: AccountSummaryFfi? { accountStore.activeAccount }

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

    func revealNsec(accountRef: String) async throws -> String {
        try await currentMarmotClient().revealNsec(accountRef: accountRef)
    }

    func exportEncryptedSecretKey(accountRef: String, passphrase: String) async throws -> String {
        try await currentMarmotClient().exportEncryptedSecretKey(
            accountRef: accountRef,
            passphrase: passphrase
        )
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
        await notificationCoordinator.drainNativePushRegistrationTaskForTesting()
    }

    /// Exposes the sign-out teardown guard (#320) so tests can assert it is
    /// raised only during `signOut()` and cleared before the function returns
    /// (so a legitimate post-sign-out reschedule is not suppressed).
    @MainActor
    var isSigningOutForTesting: Bool { isSigningOut }
    #endif
}

extension AppState: NotificationCoordinatorHost {
    func configureNotifications() {
        notifications.configure(appState: self)
    }

    var isRuntimeSuspendingForNotificationCoordinator: Bool { isRuntimeSuspending }
    var isSigningOutForNotificationCoordinator: Bool { isSigningOut }
}
