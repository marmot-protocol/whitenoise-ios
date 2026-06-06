import Foundation
import Observation
import MarmotKit

struct NotificationSubscriptionRunner {
    let initialRetryDelayNanoseconds: UInt64
    let maximumRetryDelayNanoseconds: UInt64
    let subscribe: () async throws -> AsyncStream<NotificationUpdateFfi>
    let present: (NotificationUpdateFfi) async -> Void
    let reportError: (Error) async -> Void
    let sleep: (UInt64) async throws -> Void

    init(
        initialRetryDelayNanoseconds: UInt64,
        maximumRetryDelayNanoseconds: UInt64,
        subscribe: @escaping () async throws -> AsyncStream<NotificationUpdateFfi>,
        present: @escaping (NotificationUpdateFfi) async -> Void,
        reportError: @escaping (Error) async -> Void,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.initialRetryDelayNanoseconds = initialRetryDelayNanoseconds
        self.maximumRetryDelayNanoseconds = maximumRetryDelayNanoseconds
        self.subscribe = subscribe
        self.present = present
        self.reportError = reportError
        self.sleep = sleep
    }

    func run() async {
        var retryDelay = initialRetryDelayNanoseconds

        while !Task.isCancelled {
            var deliveredNotification = false

            do {
                let updates = try await subscribe()
                for await update in updates {
                    guard !Task.isCancelled else { return }
                    deliveredNotification = true
                    retryDelay = initialRetryDelayNanoseconds
                    await present(update)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await reportError(error)
            }

            guard !Task.isCancelled else { return }

            do {
                try await sleep(retryDelay)
            } catch {
                return
            }

            if !deliveredNotification {
                retryDelay = nextDelay(after: retryDelay)
            }
        }
    }

    private func nextDelay(after delay: UInt64) -> UInt64 {
        guard delay < maximumRetryDelayNanoseconds else { return maximumRetryDelayNanoseconds }
        let doubled = delay.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { return maximumRetryDelayNanoseconds }
        return min(doubled.partialValue, maximumRetryDelayNanoseconds)
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
    private var notificationSubscriptionTask: Task<Void, Never>?
    private var foregroundActivationTask: Task<Void, Never>?
    private var nativePushRegistrationTask: Task<Void, Never>?
    private var runtimeSuspensionTask: Task<Void, Never>?
    private var isForegroundCatchUpRunning = false
    private var isRuntimeSuspending = false
    private(set) var isAppSceneActive = true
    private(set) var runtimeSuspendedForBackground = false
    private(set) var runtimeGeneration = 0

    /// Cache of best-known display names keyed by account id hex. Derived
    /// from `profiles` when available. Read-only from view code.
    private(set) var displayNames: [String: String] = [:]

    /// Cache of full Nostr kind:0 profiles keyed by account id hex. Populated
    /// on demand via `profile(forAccountIdHex:)`. Read-only from view code.
    private(set) var profiles: [String: UserProfileMetadataFfi] = [:]

    /// Cache of npub (bech32) forms keyed by account id hex. Conversion is
    /// deterministic and offline, so these never go stale.
    private(set) var npubs: [String: String] = [:]

    /// Most recent transient banner. View code reads this via the
    /// `.toastHost()` modifier on the root view.
    private(set) var activeToast: Toast?
    private var toastDismissTask: Task<Void, Never>?

    /// A profile to present (set by a scanned QR or an opened deep link).
    /// MainView binds a sheet to this.
    private(set) var pendingProfile: ProfileLink?

    struct ProfileLink: Identifiable, Equatable {
        let npub: String
        var id: String { npub }
    }

    /// A chat (group id hex) to navigate to once any presenting sheets close —
    /// set right after creating a chat from the composer or a scanned profile.
    /// ChatsListView observes this to push the conversation.
    private(set) var pendingChatId: String?
    private(set) var pendingChatAccountRef: String?
    private(set) var pendingChatMessageIdHex: String?
    private(set) var visibleChat: VisibleChatRoute?

    /// Tracks in-flight directory fetches so we don't pile up duplicate work.
    private var directoryFetchesInFlight: Set<String> = []

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
            let restored = try makeRuntime()
            client = restored
            return restored.marmot
        } catch {
            fatalError("Failed to rebuild Keychain-backed Marmot runtime: \(error)")
        }
    }

    /// Build a fresh runtime from the captured on-disk root and relay set. Used
    /// to restore the runtime after a background suspension released it.
    private func makeRuntime() throws -> MarmotClient {
        try MarmotClient(rootPath: runtimeRootPath, relayUrls: runtimeRelayUrls)
    }

    // MARK: - Bootstrap

    /// Brings the runtime online and refreshes the account list. Called once
    /// per app launch.
    func bootstrap() async {
        do {
            try await marmot.start()
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
                notifications.configure(appState: self)
                startNotificationSubscription()
                scheduleNativePushRegistrationIfEnabled()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func startNotificationSubscription() {
        notificationSubscriptionTask?.cancel()
        notificationSubscriptionTask = Task { [weak self] in
            guard let self else { return }
            let runner = NotificationSubscriptionRunner(
                initialRetryDelayNanoseconds: Self.notificationSubscriptionInitialRetryDelayNanoseconds,
                maximumRetryDelayNanoseconds: Self.notificationSubscriptionMaximumRetryDelayNanoseconds,
                subscribe: {
                    let subscription = try await self.marmot.subscribeNotifications()
                    return SubscriptionDriver.notifications(subscription)
                },
                present: { update in
                    guard self.shouldPresentLocalNotification(update) else { return }
                    await self.notifications.present(update: update)
                },
                reportError: { error in
                    self.present(
                        .error(
                            L10n.string("Notifications unavailable"),
                            message: error.localizedDescription
                        )
                    )
                }
            )
            await runner.run()
        }
    }

    private func stopNotificationSubscription() {
        notificationSubscriptionTask?.cancel()
        notificationSubscriptionTask = nil
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

    /// Signs out of the active account: clears its native push registration
    /// (so the push server stops delivering its notifications to this device)
    /// and disables its `nativePushEnabled` preference, then switches the
    /// active account to the next available local account (or `nil`).
    ///
    /// Push cleanup is best-effort — a transient marmot error here must not
    /// block the user from signing out. The account's key material stays in
    /// the Keychain so they can sign back in later.
    @MainActor
    func signOut() async {
        guard let signingOut = activeAccountRef else { return }
        try? await marmot.clearPushRegistration(accountRef: signingOut)
        _ = try? await marmot.setNativePushEnabled(accountRef: signingOut, enabled: false)

        // Refresh before selecting the next account so we read the real
        // post-sign-out list rather than one that still contains `signingOut`.
        try? await refreshAccounts()

        let next = accounts.first { $0.label != signingOut }?.label
        activeAccountRef = next

        // Last account signed out: there's nothing left to display, so tear
        // down the old account's notification subscription and route back to
        // onboarding instead of leaving the main UI up with no active account.
        if next == nil {
            stopNotificationSubscription()
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
        await cancelForegroundMaintenance()
        guard phase == .ready,
              !runtimeSuspendedForBackground,
              !isRuntimeSuspending
        else { return }

        isRuntimeSuspending = true
        stopNotificationSubscription()
        await marmot.shutdown()
        // Release the FFI handle so Rust drops the runtime and closes its
        // SQLite storage in the shared App Group container. Holding the handle
        // alive across suspension (only swapping it on resume) keeps that
        // file lock held, which is what iOS kills the app for with
        // `0xdead10cc`. Rebuilt in `resumeAfterForegroundActivation`.
        client = nil
        runtimeSuspendedForBackground = true
        isRuntimeSuspending = false
    }

    func resumeAfterForegroundActivation() async {
        isAppSceneActive = true
        while isRuntimeSuspending, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard phase == .ready, !Task.isCancelled else { return }

        if runtimeSuspendedForBackground {
            do {
                client = try makeRuntime()
                try await marmot.start()
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

    func refreshAccounts() async throws {
        let listed = try await Task.detached { [marmot] in
            try marmot.listAccounts()
        }.value
        accounts = listed
    }

    // MARK: - Identity management

    /// Generate a fresh Nostr identity. On success the new account becomes active.
    @discardableResult
    func createIdentity() async throws -> AccountSummaryFfi {
        let relays = MarmotClient.seedRelays
        let summary = try await marmot.createIdentity(
            defaultRelays: relays,
            bootstrapRelays: relays
        )
        try await refreshAccounts()
        activeAccountRef = summary.label
        if phase == .onboarding { phase = .ready }
        return summary
    }

    /// Import an existing local-signing identity (nsec).
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
        if phase == .onboarding { phase = .ready }
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

    // MARK: - Profiles & display names

    /// Full Nostr profile for an account id. Returns the cached value
    /// immediately if known; otherwise does a fast synchronous read from the
    /// runtime's directory cache, and on a miss schedules a background relay
    /// fetch so a later call hydrates. `nil` until something is known.
    @MainActor
    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        if let cached = profiles[id] { return cached }
        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(local, for: id)
            return local
        }
        Task { await refreshProfile(forAccountIdHex: id) }
        return nil
    }

    /// A display name we actually *know* for an account: projected kind:0
    /// display_name/name, then a cached name, then a local account's label.
    /// `nil` when nothing better than the raw id is available, so callers can
    /// choose their own fallback (e.g. an npub for a DM peer).
    @MainActor
    func knownDisplayName(forAccountIdHex id: String) -> String? {
        if let p = profile(forAccountIdHex: id), let name = Self.name(from: p) {
            return name
        }
        if let cached = displayNames[id] { return cached }
        if let projected = marmot.displayName(accountIdHex: id),
           let name = ProfileSanitizer.displayName(projected) {
            displayNames[id] = name
            return name
        }
        if let owned = accounts.first(where: { $0.accountIdHex == id }), !owned.label.isEmpty {
            return owned.label
        }
        return nil
    }

    /// Best-effort display name. Prefers the projected kind:0 display_name /
    /// name, then a local account's label, then short-hex.
    @MainActor
    func displayName(forAccountIdHex id: String) -> String {
        knownDisplayName(forAccountIdHex: id) ?? IdentityFormatter.short(id)
    }

    /// Picture URL for an account id, if its profile has a *safe* one.
    /// Untrusted: only http(s) URLs with a host pass the sanitizer.
    @MainActor
    func avatarURL(forAccountIdHex id: String) -> URL? {
        ProfileSanitizer.imageURL(profile(forAccountIdHex: id)?.picture)
    }

    /// Store a profile in the cache and derive its display name. Called after
    /// a successful publish so the editor and chrome update immediately.
    @MainActor
    func cacheProfile(_ profile: UserProfileMetadataFfi, for id: String) {
        profiles[id] = profile
        if let name = Self.name(from: profile) {
            displayNames[id] = name
        }
    }

    @MainActor
    private func refreshProfile(forAccountIdHex id: String) async {
        guard !directoryFetchesInFlight.contains(id) else { return }
        directoryFetchesInFlight.insert(id)
        defer { directoryFetchesInFlight.remove(id) }

        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(local, for: id)
            return
        }

        // Fetch this account's OWN kind:0 through the active account's relay
        // lists. Marmot owns those lists; iOS only asks for the current view.
        let relays = activeAccountRef.map(relayBootstrapRelays(for:)) ?? MarmotClient.seedRelays
        try? await marmot.refreshProfile(accountIdHex: id, relays: relays)

        if let fetched = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(fetched, for: id)
        } else if let name = marmot.displayName(accountIdHex: id), !name.isEmpty {
            displayNames[id] = name
        }
    }

    private static func name(from profile: UserProfileMetadataFfi) -> String? {
        // Untrusted kind:0 content — sanitize before it's used as a name.
        ProfileSanitizer.displayName(profile.displayName ?? profile.name)
    }

    // MARK: - npub

    /// The `npub…` bech32 form of an account id hex. Falls back to the hex
    /// if conversion fails (shouldn't, for a valid pubkey).
    @MainActor
    func npub(forAccountIdHex id: String) -> String {
        if let cached = npubs[id] { return cached }
        let value = marmot.npub(accountIdHex: id) ?? id
        npubs[id] = value
        return value
    }

    /// Truncated npub for compact UI (e.g. `npub1abc…wxyz`).
    @MainActor
    func shortNpub(forAccountIdHex id: String) -> String {
        IdentityFormatter.short(npub(forAccountIdHex: id))
    }

    // MARK: - Toasts

    @MainActor
    func present(_ toast: Toast) {
        toastDismissTask?.cancel()
        activeToast = toast
        let id = toast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.activeToast?.id == id else { return }
            self.activeToast = nil
        }
    }

    @MainActor
    func dismissToast() {
        toastDismissTask?.cancel()
        activeToast = nil
    }

    // MARK: - Profile routing (QR scan / deep link)

    @MainActor
    func presentProfile(npub: String) {
        pendingProfile = ProfileLink(npub: npub)
    }

    @MainActor
    func clearPendingProfile() {
        pendingProfile = nil
    }

    /// Request navigation into a chat (e.g. just after creating one).
    @MainActor
    func presentChat(groupIdHex: String, accountRef: String? = nil, messageIdHex: String? = nil) {
        if let accountRef, !accountRef.isEmpty {
            activeAccountRef = accountRef
            pendingChatAccountRef = accountRef
        } else {
            pendingChatAccountRef = nil
        }
        let messageId = messageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingChatMessageIdHex = messageId?.isEmpty == false ? messageId : nil
        pendingChatId = groupIdHex
    }

    @MainActor
    func presentNotification(route: LocalNotificationRoute) {
        presentChat(
            groupIdHex: route.groupIdHex,
            accountRef: route.accountRef,
            messageIdHex: route.messageIdHex
        )
    }

    @MainActor
    func clearPendingChat() {
        pendingChatId = nil
        pendingChatAccountRef = nil
        pendingChatMessageIdHex = nil
    }

    @MainActor
    @discardableResult
    func beginViewingChat(groupIdHex: String) -> VisibleChatRoute? {
        guard let accountRef = activeAccountRef else { return nil }
        let route = VisibleChatRoute(accountRef: accountRef, groupIdHex: groupIdHex)
        visibleChat = route
        return route
    }

    @MainActor
    func endViewingChat(_ route: VisibleChatRoute) {
        if visibleChat == route {
            visibleChat = nil
        }
    }

    func isViewingNotificationDestination(accountRef: String, groupIdHex: String) -> Bool {
        !LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: isAppSceneActive,
            updateAccountRef: accountRef,
            updateGroupIdHex: groupIdHex,
            visibleChat: visibleChat
        )
    }

    /// Route an inbound deep link (from `.onOpenURL`).
    @MainActor
    func handle(url: URL) {
        switch DeepLink.parse(url) {
        case .profile(let npub):
            presentProfile(npub: npub)
        case .chat(let groupIdHex):
            presentChat(groupIdHex: groupIdHex)
        case nil:
            break
        }
    }
}
