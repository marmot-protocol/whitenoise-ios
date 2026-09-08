import Foundation
import Observation
import OSLog
import MarmotKit
import UserNotifications

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

struct ForegroundMaintenanceTasks {
    let notificationSubscription: Task<Void, Never>?
    let connectivityCatchUp: Task<Void, Never>?
    let profileRefresh: Task<Void, Never>?
    let mutationFollowups: [Task<Void, Never>]
}

/// Bounded, account-scoped handoff from direct-chat creation to the chat-list
/// projection. A newly created unnamed group reaches the list before its roster
/// details do, even though the creation path already knows the other account.
struct RecentDirectChatPeerStore {
    private struct Entry: Equatable {
        let groupIdHex: String
        let peerAccountIdHex: String
    }

    private let maxAccounts: Int
    private let maxGroupsPerAccount: Int
    private var entriesByAccountRef: [String: [Entry]] = [:]
    private var accountRecency: [String] = []

    init(maxAccounts: Int = 4, maxGroupsPerAccount: Int = 64) {
        self.maxAccounts = max(1, maxAccounts)
        self.maxGroupsPerAccount = max(1, maxGroupsPerAccount)
    }

    mutating func record(accountRef: String, groupIdHex: String, peerAccountIdHex: String) {
        guard !accountRef.isEmpty, !groupIdHex.isEmpty, !peerAccountIdHex.isEmpty else { return }
        var entries = entriesByAccountRef[accountRef] ?? []
        entries.removeAll { $0.groupIdHex == groupIdHex }
        entries.append(Entry(groupIdHex: groupIdHex, peerAccountIdHex: peerAccountIdHex))
        entriesByAccountRef[accountRef] = Array(entries.suffix(maxGroupsPerAccount))
        touch(accountRef)
        while accountRecency.count > maxAccounts {
            entriesByAccountRef[accountRecency.removeFirst()] = nil
        }
    }

    func peerAccountId(accountRef: String, groupIdHex: String) -> String? {
        entriesByAccountRef[accountRef]?.last(where: { $0.groupIdHex == groupIdHex })?.peerAccountIdHex
    }

    private mutating func touch(_ accountRef: String) {
        accountRecency.removeAll { $0 == accountRef }
        accountRecency.append(accountRef)
    }
}

/// Bounded handoff for the exact durable projection returned by detailed
/// group creation. This lets navigation render without another FFI read while
/// the chat-list subscription catches up.
struct RecentCreatedChatRowStore {
    private let maximumRows: Int
    private var rowsByKey: [String: ChatListRowFfi] = [:]
    private var recency: [String] = []

    init(maximumRows: Int = 64) {
        self.maximumRows = max(1, maximumRows)
    }

    mutating func record(accountRef: String, row: ChatListRowFfi) {
        guard !accountRef.isEmpty, !row.groupIdHex.isEmpty else { return }
        let key = Self.key(accountRef: accountRef, groupIdHex: row.groupIdHex)
        rowsByKey[key] = row
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > maximumRows {
            rowsByKey[recency.removeFirst()] = nil
        }
    }

    func row(accountRef: String, groupIdHex: String) -> ChatListRowFfi? {
        rowsByKey[Self.key(accountRef: accountRef, groupIdHex: groupIdHex)]
    }

    private static func key(accountRef: String, groupIdHex: String) -> String {
        "\(accountRef)\u{1f}\(groupIdHex)"
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

    nonisolated enum Phase: Equatable {
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
    /// Read by `RuntimeLifecycle` through its back-reference.
    var phaseOwnsLiveRuntime: Bool {
        phase == .ready || phase == .onboarding
    }

    /// Mutator used by `RuntimeLifecycle` (which owns bootstrap/resume) to drive
    /// the router; `phase` stays `private(set)` so feature code can't write it.
    func setPhase(_ newPhase: Phase) {
        phase = newPhase
    }

    /// Account list + active selection. Owned by `AccountStore`; these forwarders
    /// keep the `appState.accounts` / `activeAccountRef` / `activeAccount` call
    /// sites and SwiftUI observation unchanged. AppState still drives the Marmot
    /// account refresh and the identity lifecycle (create / import / sign-out).
    @ObservationIgnored let accountStore: AccountStore
    var accounts: [AccountSummaryFfi] { accountStore.accounts }

    private(set) var isErasingAppData = false
    var appDataErasureGeneration = 0
    var openSettingsAfterProfileSelection = false
    let erasureState: AppDataErasureState
    let signInAttempts: SignInAttemptStore
    var productContextRevision = UUID()
    var productConsentMutationInProgress = false
    var productOnboardingPath: ProductOnboardingPath?
    var productOnboardingTicket: ProductAnalyticsRecorder.Ticket?
    let productAnalytics = ProductAnalyticsRecorder()
    var pendingProductActivity: ProductAnalyticsActivityFfi = .foreground
    let diagnosticsConsent: DeviceDiagnosticsConsent
    var pendingAccountSetup: AccountSetupModel?
    private(set) var accountSetupSnapshots: [OnboardingSnapshotFfi] = []
    private(set) var onboardingRecoveryAccounts: [AccountSummaryFfi] = []
    var isAccountSetupPresented = false
    private(set) var isFinishingAccountSetup = false
    private static let accountRefreshLog = Logger(subsystem: "dev.ipf.whitenoise", category: "account-refresh")
#if DEBUG
    @ObservationIgnored var beforeAccountRefreshForTesting: (() async throws -> Void)?
    @ObservationIgnored var beforeOnboardingSnapshotReadForTesting: ((String) async throws -> Void)?
#endif

    func cancelAccountSetup() async -> Bool {
        guard !isFinishingAccountSetup, let model = pendingAccountSetup,
              let lease = try? runtimeLifecycle.beginForegroundRuntimeMutation() else { return false }
        isFinishingAccountSetup = true
        defer {
            isFinishingAccountSetup = false
            runtimeLifecycle.endForegroundRuntimeMutation(lease)
        }
        model.suspend()
        do {
            // Cancel in MDK before draining a host operation that may be awaiting publication.
            try await lease.client.marmot.cancelOnboarding(accountRef: model.accountID)
            await model.drain()
            productAnalytics.record(.onboarding(.complete, .import, .cancelled), ticket: productOnboardingTicket)
            productOnboardingTicket = nil
            productOnboardingPath = nil
            signInAttempts.finish(model.accountID)
            pendingAccountSetup = nil
            isAccountSetupPresented = false
            do { try await refreshAccounts(refreshUnreadSummaries: false) } catch {
                present(.error(L10n.string("Couldn’t refresh your accounts. Try again.")))
            }
            if activeAccountRef == nil { phase = accounts.contains { !$0.signedOut } ? .ready : .onboarding }
            return true
        } catch {
            model.errorMessage = L10n.string("Couldn’t close sign-in. Try again when the current update has finished.")
            return false
        }
    }

    func connectAccountSetup() async {
        guard !isFinishingAccountSetup, let model = pendingAccountSetup, canUseRuntimeForLocalForegroundWork,
              let client = try? runtimeClient() else { return }
        await model.connect(MarmotAccountSetupClient(client: client, accountID: model.accountID))
    }

    func finishAccountSetup() async {
        guard !isFinishingAccountSetup,
              let model = pendingAccountSetup, model.canFinish,
              let lease = try? runtimeLifecycle.beginForegroundRuntimeMutation() else { return }
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        isFinishingAccountSetup = true
        defer { isFinishingAccountSetup = false }
        let completed = model.snapshot.ready && !model.cancelled
        let id = model.accountID
        signInAttempts.finish(id)
        model.suspend()
        await model.drain()
        pendingAccountSetup = nil
        isAccountSetupPresented = false
        do {
            try await refreshAccounts(refreshUnreadSummaries: false)
            if completed, let summary = accounts.first(where: { $0.accountIdHex == id }) {
                await productAnalytics.record(.onboarding(.complete, .import, .success), ticket: productOnboardingTicket)?.value
                productOnboardingTicket = nil
                productOnboardingPath = nil
                await activateNewIdentity(summary)
            } else if model.cancelled, !accounts.isEmpty {
                phase = .ready
            }
        } catch {
            signInAttempts.begin(id)
            pendingAccountSetup = model
            isAccountSetupPresented = true
            model.errorMessage = L10n.string("Couldn’t refresh your accounts. Try again.")
        }
    }

    /// Per-account unread totals (account-switcher badges). Owned by
    /// `AccountUnreadStore`; this read-only forwarder keeps the
    /// `appState.accountUnreadSummariesByAccountId` call sites and SwiftUI
    /// observation of the badges unchanged.
    @ObservationIgnored let accountUnreadStore = AccountUnreadStore()
    var accountUnreadSummariesByAccountId: [String: AccountUnreadFfi] {
        accountUnreadStore.byAccountId
    }

    /// Account/group-scoped composer drafts. Marmot owns encrypted persistence;
    /// this store keeps the shared in-memory summary and pending-write projection.
    @ObservationIgnored let conversationDraftStore: ConversationDraftStore

    /// The account whose chats / messages are currently displayed.
    /// `nil` only between bootstrap and onboarding completion. Backed by
    /// `AccountStore` (which persists it to UserDefaults).
    var activeAccountRef: String? {
        get { accountStore.activeAccountRef }
        set {
            let previous = accountStore.activeAccountRef
            accountStore.activeAccountRef = newValue
            if previous != newValue { productAccountChanged() }
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

    /// Blocks screenshots and screen recordings of app content while on
    /// (window-level capture exclusion, applied by `WindowCaptureProtection`).
    /// Off by default; toggled in Settings → Privacy & Security.
    var blockScreenshots: Bool {
        didSet {
            UserDefaults.standard.set(blockScreenshots, forKey: Self.blockScreenshotsKey)
        }
    }

    /// Recently-used reaction emojis, most-recent first. Drives the quick row
    /// in the message actions overlay.
    private(set) var recentReactions: [String]
    private(set) var customizedQuickReactions: [String]?

    nonisolated static let defaultReactions = ["❤️", "👍", "👎", "😂", "😮", "😢"]

    /// The six emojis to show in the quick-reaction row. Before the user
    /// customizes it, recents are topped up with defaults; a saved selection is
    /// stable until explicitly changed or reset.
    var quickReactions: [String] {
        QuickReactionChoices.resolved(
            customized: customizedQuickReactions,
            recent: recentReactions
        )
    }

    func addRecentReaction(_ emoji: String) {
        var list = recentReactions.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentReactions = Array(list.prefix(12))
        UserDefaults.standard.set(recentReactions, forKey: Self.recentReactionsKey)
    }

    func setQuickReactions(_ choices: [String]) {
        let normalized = QuickReactionPreferences.save(choices, to: .standard)
        customizedQuickReactions = normalized
    }

    func resetQuickReactions() {
        setQuickReactions(Self.defaultReactions)
    }

    /// Runtime-lifecycle ownership: the live `MarmotClient`, the
    /// foreground/suspension gates, the runtime generation, bootstrap, and the
    /// background suspend / foreground resume orchestration. Carved out of
    /// `AppState` (Phase 2); AppState keeps the thin forwarders below so call
    /// sites are unchanged. Wired (`configure(appState:)`) in init.
    @ObservationIgnored let runtimeLifecycle: RuntimeLifecycle

    /// The live FFI runtime. Released (`nil`) while the app is suspended in the
    /// background so its SQLite storage in the shared App Group container is
    /// closed and its file lock freed — otherwise iOS terminates the app at
    /// suspension with `0xdead10cc` ("held a file lock in a shared container").
    /// Rebuilt on foreground in `resumeAfterForegroundActivation`. Owned by
    /// `RuntimeLifecycle`; this computed forwarder keeps the `appState.client`
    /// call sites (and the AppState-internal notification/settings reads)
    /// unchanged. Not observed (it forwards to `RuntimeLifecycle`'s
    /// `@ObservationIgnored client`), matching the original raw-handle semantics.
    var client: MarmotClient? { runtimeLifecycle.client }
    let notifications: AppNotifications
    @ObservationIgnored let notificationCoordinator = NotificationCoordinator()
    let toastState = ToastState()
    let navigation = NavigationState()
    /// Optional local-auth gate and app-switcher privacy shield. UI-only:
    /// runtime suspend/resume stays independent of the lock state.
    let appLock = AppLockController()
    /// Profile projection cache + hydration/refresh queues. `profileRefreshGeneration`
    /// stays on AppState (below) as the observed token; the store reads/bumps it
    /// through its back-reference so SwiftUI observation is unchanged.
    @ObservationIgnored let profileStore = ProfileStore()
    @ObservationIgnored private var recentDirectChatPeers = RecentDirectChatPeerStore()
    @ObservationIgnored private var recentCreatedChatRows = RecentCreatedChatRowStore()
    /// True only while `signOut()` is tearing down the departing account. Set
    /// before any of sign-out's `await` suspension points and cleared once the
    /// account is removed and `accounts` refreshed. `scheduleNativePushRegistrationIfEnabled()`
    /// consults this so a system-driven APNS token arriving mid-sign-out cannot
    /// spawn a fresh registration sync that re-`upsertPushRegistration`s the
    /// account whose registration sign-out just cleared (#320, residual of
    /// #7/#111). MainActor-owned; mutated only on the MainActor.
    private var isSigningOut = false
    @ObservationIgnored private var accountExitWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Account refs with an activation already running. Set before signed-out
    /// reactivation awaits so rapid repeated taps cannot start duplicate sign-ins.
    /// MainActor-owned; mutated only by `activateAccount`.
    private var activatingAccountRefs = Set<String>()
    @ObservationIgnored private var pendingAccountSetupReadiness: [String: AccountSetupReadinessFfi] = [:]
    /// Scene-phase flag. Owned here (not on `RuntimeLifecycle`) because many
    /// non-lifecycle gates read it (notification presentation, settings reads,
    /// push scheduling, routing); `RuntimeLifecycle` writes it through its
    /// back-reference from the scene-phase entry points so every gate computes
    /// the same boolean.
    var isAppSceneActive = true
    /// False until any scene-phase entry point runs this launch. A UI-less
    /// background launch (notification action on a terminated app) never
    /// reports a phase while `isAppSceneActive` keeps its optimistic launch
    /// default, so the pair distinguishes "scene is active" from "no scene
    /// ever spoke". Written by `RuntimeLifecycle` alongside `isAppSceneActive`.
    var sceneHasReportedPhase = false
    private(set) var profileRefreshGeneration = 0

    /// Foreground expiration-sweep loop for disappearing messages. Started
    /// with the other `.ready` foreground maintenance and cancelled on
    /// background suspension.
    @ObservationIgnored private let retentionSweeper = MessageRetentionSweeper()
    /// Bumped after a sweep pruned expired records; open conversations observe
    /// it and reload their timeline window when their group is affected.
    private(set) var retentionSweepGeneration = 0
    private(set) var retentionSweepPrunedGroupIds: Set<String> = []

    /// Forwarders to `RuntimeLifecycle`, which owns the runtime-gate state. Keep
    /// the `appState.runtimeSuspendedForBackground` / `isRuntimeWarmingUp` /
    /// `runtimeGeneration` call sites (views, view models, policies, tests) and
    /// SwiftUI observation unchanged.
    var runtimeSuspendedForBackground: Bool { runtimeLifecycle.runtimeSuspendedForBackground }
    var isRuntimeWarmingUp: Bool { runtimeLifecycle.isRuntimeWarmingUp }
    var runtimeGeneration: Int { runtimeLifecycle.runtimeGeneration }

    var runtimeEventsGeneration: Int? {
        guard phaseOwnsLiveRuntime, !runtimeSuspendedForBackground, !isRuntimeSuspending,
              client != nil else { return nil }
        return runtimeGeneration
    }

    func observeRuntimeEvents() async {
        guard let generation = runtimeEventsGeneration, let client else { return }
        let subscription = client.subscribeEvents()
        for await event in SubscriptionDriver.events(subscription) {
            guard !Task.isCancelled, runtimeEventsGeneration == generation else { return }
            handleRuntimeEvent(event, generation: generation)
        }
    }

    var groupRecoveryUpdate: GroupRecoveryUpdate?

    struct GroupRecoveryUpdate: Equatable {
        let accountID: String
        let groupID: String
        let id = UUID()
    }

    func handleRuntimeEvent(_ event: MarmotEventFfi, generation: Int) {
        guard runtimeEventsGeneration == generation else { return }
        if case .groupStateUpdated(let accountID, _, let groupID) = event,
           activeAccount?.accountIdHex == accountID,
           visibleChat?.groupIdHex == groupID {
            groupRecoveryUpdate = GroupRecoveryUpdate(accountID: accountID, groupID: groupID)
        }
        guard runtimeEventsGeneration == generation,
              case .groupChangeSuperseded(let accountID, _, _, _, _, _, _) = event,
              accounts.contains(where: { $0.accountIdHex == accountID && !$0.signedOut }),
              let notice = GroupChangeNotice.toast(for: event) else { return }
        present(notice)
    }

    /// Whether the runtime is mid-suspension. AppState-internal only: the
    /// notification-presentation and settings-read gates that stay on AppState
    /// read it bare.
    private var isRuntimeSuspending: Bool { runtimeLifecycle.isRuntimeSuspendingNow }

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
    /// Live runtime config when present, cached fallback while suspended.
    /// Forwards to `RuntimeLifecycle` (which holds both the client and the
    /// fallback); do not recompute `TelemetryBuildConfig.current()` here.
    var telemetryBuildConfig: TelemetryBuildConfig { runtimeLifecycle.telemetryBuildConfig }
    var notificationSubscriptionActive: Bool { notificationCoordinator.notificationSubscriptionActive }
    var isConnectivityCatchUpInProgress: Bool { notificationCoordinator.isForegroundCatchUpRunning }
    var canRefreshProfiles: Bool { runtimeLifecycle.canRefreshProfiles }
    var canUseRuntimeForLocalForegroundWork: Bool { runtimeLifecycle.canUseRuntimeForLocalForegroundWork }
    var canUseRuntimeForForegroundWork: Bool { runtimeLifecycle.canUseRuntimeForForegroundWork }

    private static let developerModeKey = "marmot.developerMode"
    private static let streamingDebugModeKey = "marmot.streamingDebugMode"
    private static let blockScreenshotsKey = "marmot.blockScreenshots"
    private static let recentReactionsKey = "marmot.recentReactions"
    private static let defaultSuspendedRuntimeTelemetryBuildConfig = TelemetryBuildConfig.current()
    static let agentTextStreamQuicBrokerCandidate = "quic://quic-broker.ipf.dev:4450"
    static let agentTextStreamQuicCandidates = [agentTextStreamQuicBrokerCandidate]

    init(
        client: MarmotClient?,
        notifications: AppNotifications,
        conversationDraftStore: ConversationDraftStore? = nil,
        accountDefaults: UserDefaults = .standard,
        erasureDefaults: UserDefaults = AppDataErasureState.persistentDefaults,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig = AppState.defaultSuspendedRuntimeTelemetryBuildConfig,
        runtimeClientFactory: @escaping RuntimeLifecycle.RuntimeClientFactory =
            RuntimeLifecycle.defaultRuntimeClientFactory,
        runtimeRetrySleeper: @escaping RuntimeLifecycle.RetrySleeper = {
            delay in try await Task.sleep(for: delay)
        },
        runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy = .foreground
    ) {
        self.runtimeLifecycle = RuntimeLifecycle(
            client: client,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig,
            runtimeClientFactory: runtimeClientFactory,
            retrySleeper: runtimeRetrySleeper,
            constructionRetryPolicy: runtimeConstructionRetryPolicy
        )
        self.accountStore = AccountStore(defaults: accountDefaults)
        self.notifications = notifications
        self.conversationDraftStore = conversationDraftStore ?? ConversationDraftStore()
        self.erasureState = AppDataErasureState(defaults: erasureDefaults, legacyDefaults: accountDefaults)
        self.signInAttempts = SignInAttemptStore(defaults: accountDefaults)
        self.diagnosticsConsent = DeviceDiagnosticsConsent(defaults: accountDefaults)
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        self.streamingDebugMode = UserDefaults.standard.bool(forKey: Self.streamingDebugModeKey)
        self.blockScreenshots = UserDefaults.standard.bool(forKey: Self.blockScreenshotsKey)
        self.recentReactions = UserDefaults.standard.stringArray(forKey: Self.recentReactionsKey)
            ?? Self.defaultReactions
        self.customizedQuickReactions = QuickReactionPreferences.load(from: .standard)
        self.profileStore.appState = self
        self.runtimeLifecycle.configure(appState: self)
        self.conversationDraftStore.configure(persistence: self)
    }

    convenience init(client: MarmotClient) {
        self.init(client: client, notifications: .shared)
    }

    deinit {
        // ProfileStore cancels its own tasks in its deinit.
        // RuntimeLifecycle cancels its own lifecycle tasks in its deinit.
        // NotificationCoordinator cancels its native-push task in its deinit.
    }

    func noteProfileRefreshCompleted() {
        profileRefreshGeneration += 1
    }

    func noteDirectChatPeer(
        accountRef: String,
        groupIdHex: String,
        peerAccountIdHex: String
    ) {
        recentDirectChatPeers.record(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            peerAccountIdHex: peerAccountIdHex
        )
    }

    func directChatPeerAccountId(accountRef: String, groupIdHex: String) -> String? {
        recentDirectChatPeers.peerAccountId(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func noteCreatedChatListRow(accountRef: String, row: ChatListRowFfi) {
        recentCreatedChatRows.record(accountRef: accountRef, row: row)
    }

    func createdChatListRow(accountRef: String, groupIdHex: String) -> ChatListRowFfi? {
        recentCreatedChatRows.row(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    /// Production entry point. Runtime construction belongs to bootstrap so the
    /// single lifecycle owner can retry temporary cross-process root contention
    /// without trapping during SwiftUI app initialization.
    convenience init() {
        self.init(client: nil, notifications: .shared)
    }

    // Redacted crash messages for unrecoverable Keychain/storage init and
    // runtime errors. Surface only the error type, never its description, so
    // internal Keychain/storage details can't leak into crash logs (#21).
    static func redactedStorageInitFailureMessage(for error: Error) -> String {
        "Failed to initialize durable Marmot storage (\(type(of: error)))"
    }

    static func redactedRuntimeRebuildFailureMessage(for error: Error) -> String {
        "Failed to rebuild Keychain-backed Marmot runtime (\(type(of: error)))"
    }

    func currentMarmotClient() throws -> MarmotClient {
        try runtimeClient()
    }

    private func runtimeClient() throws -> MarmotClient {
        try runtimeLifecycle.runtimeClient()
    }

    // MARK: - Bootstrap

    /// Brings the runtime online and refreshes the account list. Called once
    /// per app launch. Owned by `RuntimeLifecycle`; this forwarder keeps the
    /// `appState.bootstrap()` scene-task call site unchanged.
    @MainActor
    func bootstrap() async {
        await runtimeLifecycle.bootstrap()
    }

    @MainActor
    private func completeOnboardingAfterIdentityActivation(scheduleNativePushRegistration: Bool = true) {
        guard phase == .onboarding else { return }
        phase = .ready
        startReadyForegroundMaintenance(scheduleNativePushRegistration: scheduleNativePushRegistration)
    }

    /// Signing out of the last signed-in account stops the notification
    /// subscription and retention sweeper but keeps the `.ready` shell alive
    /// for reactivation. Activating an account from that shell must restart
    /// both loops; ordinary account switches never stopped the subscription,
    /// so the liveness guard keeps this a no-op there.
    @MainActor
    private func restartReadyForegroundMaintenanceIfStopped() {
        guard phase == .ready, !notificationCoordinator.notificationSubscriptionActive else { return }
        startReadyForegroundMaintenance(scheduleNativePushRegistration: false)
    }

    /// Internal (not `private`) so `RuntimeLifecycle.performBootstrap` can hand
    /// back the account-scoped maintenance once the runtime is ready.
    @MainActor
    func startReadyForegroundMaintenance(scheduleNativePushRegistration: Bool = true) {
        notificationCoordinator.startReadyForegroundMaintenance(
            host: self,
            scheduleNativePushRegistration: scheduleNativePushRegistration
        )
        startRetentionSweeps()
    }

    /// Internal (not `private`) so the `RuntimeLifecycle` resume path can
    /// restart the sweep loop once a `.ready` runtime is back online.
    @MainActor
    func startRetentionSweeps() {
        retentionSweeper.start(appState: self)
    }

    /// Awaited drain used by `RuntimeLifecycle.cancelForegroundMaintenance` so
    /// no sweep FFI call is in flight when suspension releases the runtime.
    func cancelRetentionSweeps() async {
        await retentionSweeper.cancel()
    }

    @MainActor
    func noteRetentionSweepCompleted(prunedGroupIds: Set<String>) {
        retentionSweepPrunedGroupIds = prunedGroupIds
        retentionSweepGeneration += 1
    }

    /// Internal (not `private`) so the `RuntimeLifecycle` resume path can start
    /// the subscription once a `.ready` runtime is back online.
    @MainActor
    func startNotificationSubscription() {
        notificationCoordinator.startNotificationSubscription(host: self)
    }

    /// Internal (not `private`) so `RuntimeLifecycle` can stop the subscription
    /// from its suspend and startup-failure-release paths.
    @discardableResult
    func stopNotificationSubscription() -> Task<Void, Never>? {
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
    /// raw `marmot` / `runtimeClient()` accessors so background tasks fail closed
    /// after suspension deliberately releases the App Group SQLite store.
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
        guard !isSigningOut else { return }
        guard accountRef != activeAccountRef else { return }
        guard let account = accounts.first(where: { $0.label == accountRef }) else { return }
        guard activatingAccountRefs.insert(accountRef).inserted else { return }
        defer { activatingAccountRefs.remove(accountRef) }

        if account.signedOut {
            do {
                let activationClient = try currentMarmotClient()
                _ = try await activationClient.signInAccount(accountRef: accountRef)
                try await refreshAccounts()
            } catch {
                present(UserFacingError.toast(title: L10n.string("Couldn't sign in"), error: error))
                return
            }
        }

        guard accounts.contains(where: { $0.label == accountRef && !$0.signedOut }) else { return }
        activeAccountRef = accountRef

        restartReadyForegroundMaintenanceIfStopped()
        scheduleNativePushRegistrationIfEnabled()
    }

    /// Set after a destructive Sign Out & Wipe finished with best-effort
    /// failures, so the partial-failure report survives the account teardown:
    /// routing to onboarding (last account) or switching accounts pops the
    /// screen that started the wipe. Hosted by `RootView`. Observed by SwiftUI.
    var pendingWipeReport: WipeReport?

    /// Non-destructively signs out of the active account: clears its native
    /// push registration, deactivates it in Marmot, and opens profile selection. The account row, keys, encrypted store, media,
    /// and drafts stay on device so the Profiles screen can sign it back in.
    ///
    /// Push cleanup is best-effort — a transient marmot error here must not
    /// block the user from signing out.
    @MainActor
    @discardableResult
    func signOut() async -> Bool {
        guard let signingOut = activeAccountRef else { return false }
        guard AccountExitGate.canBegin(
            isReady: phase == .ready,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: client != nil
        ), !isSigningOut else {
            present(.error(L10n.string("Couldn't sign out")))
            return false
        }
        let signingOutAccountIdHex = accounts
            .first(where: { $0.label == signingOut })?
            .accountIdHex
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
        defer { finishAccountExit() }
        guard let exitingClient = client else {
            present(.error(L10n.string("Couldn't sign out")))
            return false
        }
        let nativePushWasEnabled = (
            try? await exitingClient
                .notificationSettings(accountRef: signingOut)
                .nativePushEnabled
        ) ?? false
#if DEBUG
        if let afterAccountExitClientCapturedForTesting {
            await afterAccountExitClientCapturedForTesting()
        }
#endif
        await notificationCoordinator.cancelNativePushRegistrationTask()
        _ = try? await exitingClient.marmot.clearPushRegistration(accountRef: signingOut)
        _ = try? await exitingClient.marmot.setNativePushEnabled(accountRef: signingOut, enabled: false)

        do {
            let outcome = try await exitingClient.signOut(accountRef: signingOut)
            guard outcome.localCleanup.completed else {
                let message = outcome.localCleanup.reason
                    ?? L10n.string("Local account cleanup did not finish.")
                await restoreNativePushAfterFailedSignOut(
                    using: exitingClient,
                    accountRef: signingOut,
                    wasEnabled: nativePushWasEnabled
                )
                present(.error(L10n.string("Couldn't sign out"), message: message))
                return false
            }
        } catch {
            await restoreNativePushAfterFailedSignOut(
                using: exitingClient,
                accountRef: signingOut,
                wasEnabled: nativePushWasEnabled
            )
            present(UserFacingError.toast(title: L10n.string("Couldn't sign out"), error: error))
            return false
        }

        _ = await completeSignOut(
            removedRef: signingOut,
            removedAccountIdHex: signingOutAccountIdHex,
            destructive: false
        )
        return true
    }

    /// App-state cleanup shared by normal sign-out and destructive wipe. A
    /// normal sign-out keeps account-scoped local state and leaves a signed-out
    /// row available for reactivation; a wipe removes its drafts/projections
    /// and may return the app to onboarding when no accounts remain.
    @MainActor
    private func completeSignOut(
        removedRef: String,
        removedAccountIdHex: String?,
        destructive: Bool
    ) async -> [WipeFailureItem] {
        var localCleanupFailures: [WipeFailureItem] = []
        if destructive {
            conversationDraftStore.removeDrafts(accountRef: removedRef)
            await conversationDraftStore.flush()
            MessageHideStore.clearAll(accountRef: removedRef)

            // Drop the wiped account's private contact nicknames so they don't
            // outlive the identity on this device. Only on a destructive wipe —
            // a normal sign-out retains the account (and its local state,
            // including nicknames) for reactivation.
            if let removedAccountIdHex {
                profileStore.clearContactNicknames(ownerAccountIdHex: removedAccountIdHex)
                // The wiped identity's per-chat mute and notify-mode entries
                // live in the shared suite for the NSE; they must not outlive
                // the account either.
                ChatMuteStore.clearAll(accountIdHex: removedAccountIdHex)
            }
            if await !NotificationCommunicationDecorator.deleteAllDonatedInteractions() {
                localCleanupFailures.append(WipeFailureItem(
                    subject: nil,
                    reason: L10n.string("Some notification previews may remain on this device.")
                ))
            }
            if await !MessageMediaCache.purgeAllDecryptedMedia() {
                localCleanupFailures.append(WipeFailureItem(
                    subject: nil,
                    reason: L10n.string("Some decrypted media may remain on this device.")
                ))
            }
        }

        do {
            try await refreshAccounts()
        } catch {
            if destructive {
                accountStore.accounts.removeAll { $0.label == removedRef }
            }
            accountUnreadStore.pruneToCurrentAccounts(accounts)
            scheduleApplicationBadgeSynchronization()
            if destructive {
                localCleanupFailures.append(WipeFailureItem(
                    subject: nil,
                    reason: "\(L10n.string("Couldn't refresh accounts")): \(error.localizedDescription)"
                ))
            } else {
                present(UserFacingError.toast(title: L10n.string("Couldn't refresh accounts"), error: error))
            }
        }

        accountStore.requestProfileSelection()
        if !accounts.contains(where: { !$0.signedOut }) {
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
            retentionSweeper.cancelWithoutAwaiting()
            phase = .onboarding
        } else {
            if destructive, let removedAccountIdHex {
                profileStore.clearForAccountRemoval(accountIdHex: removedAccountIdHex)
            }
            // Remaining signed-in profiles require an explicit selection.
            stopNotificationSubscription()
            retentionSweeper.cancelWithoutAwaiting()
            phase = accounts.contains(where: { !$0.signedOut }) ? .ready : .onboarding
        }

        // The account mutation is now complete. Release a pending background
        // suspension before scheduling work for the surviving active profile;
        // the scheduling gate will correctly skip it if the scene already left
        // the foreground.
        finishAccountExit()
        if activeAccountRef != nil {
            scheduleNativePushRegistrationIfEnabled()
        }
        return localCleanupFailures
    }

    /// Destructive "Sign Out & Wipe" of the active account. Drives the engine's
    /// `signOutAndWipe` (leave MLS groups, delete relay KeyPackages, wipe the
    /// local store, keys, and media) then runs the same post-sign-out cleanup
    /// the normal sign-out does. Native push is cleared per the existing
    /// sign-out rules before the wipe; a total FFI failure rolls push back and
    /// toasts. A finished wipe with best-effort failures surfaces a `WipeReport`
    /// (what remains) rather than aborting — the local removal proceeds either
    /// way, mirroring the Android outcome semantics.
    ///
    /// Suspension safety: the destructive teardown only begins with a live
    /// foreground runtime (scene active, not suspended/suspending, client
    /// present) so it can never reopen the App Group SQLite store after
    /// suspension released it (`0xdead10cc`). This is the union of the guarded
    /// settings-read gate and the `.ready` gate the audit-log delete uses.
    @MainActor
    @discardableResult
    func signOutAndWipeActiveAccount() async -> Bool {
        guard let wipingRef = activeAccountRef else { return false }
        guard DestructiveWipeGate.canBegin(
            isReady: phase == .ready,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: client != nil
        ), !isSigningOut else {
            present(.error(L10n.string("Couldn't wipe profile")))
            return false
        }
        let wipingAccountIdHex = accounts
            .first(where: { $0.label == wipingRef })?
            .accountIdHex

        // Same #320 guard the normal sign-out uses: block any APNS-token-driven
        // push reschedule for the whole teardown; cleared before routing so a
        // reschedule for the *new* active account is not suppressed.
        isSigningOut = true
        defer { finishAccountExit() }
        guard let exitingClient = client else {
            present(.error(L10n.string("Couldn't wipe profile")))
            return false
        }
        let nativePushWasEnabled = (
            try? await exitingClient
                .notificationSettings(accountRef: wipingRef)
                .nativePushEnabled
        ) ?? false
#if DEBUG
        if let afterAccountExitClientCapturedForTesting {
            await afterAccountExitClientCapturedForTesting()
        }
#endif
        // Sign-out push rule: cancel and await the in-flight native-push
        // registration sync before clearing the departing account's registration.
        await notificationCoordinator.cancelNativePushRegistrationTask()
        _ = try? await exitingClient.marmot.clearPushRegistration(accountRef: wipingRef)
        _ = try? await exitingClient.marmot.setNativePushEnabled(accountRef: wipingRef, enabled: false)

        let outcome: WipeOutcomeFfi
        do {
            outcome = try await exitingClient.signOutAndWipe(accountRef: wipingRef)
        } catch {
            // Total FFI failure: nothing was wiped. Roll native push back and toast.
            await restoreNativePushAfterFailedSignOut(
                using: exitingClient,
                accountRef: wipingRef,
                wasEnabled: nativePushWasEnabled
            )
            present(UserFacingError.toast(title: L10n.string("Couldn't wipe profile"), error: error))
            return false
        }

        // The wipe returned: the account ref is invalid now. Do the same local
        // removal + routing the normal sign-out does — regardless of per-stage
        // best-effort failures — then surface a report only when something remains.
        let localCleanupFailures = await completeSignOut(
            removedRef: wipingRef,
            removedAccountIdHex: wipingAccountIdHex,
            destructive: true
        )

        let report = WipeReportProjection.report(
            from: outcome,
            additionalLocalFailures: localCleanupFailures
        )
        if report.clean {
            present(.success(L10n.string("Profile wiped from this device")))
        } else {
            pendingWipeReport = report
        }
        return true
    }

    func eraseAppData() async throws {
        guard !isErasingAppData, !isSigningOut, phaseOwnsLiveRuntime,
              canUseRuntimeForLocalForegroundWork, let erasingClient = client else {
            throw ForegroundRuntimeMutationError.runtimeUnavailable
        }
        erasureState.begin()
        isErasingAppData = true
        isSigningOut = true
        AvatarCacheErasure.begin()
        defer {
            AvatarCacheErasure.end()
            isErasingAppData = false
            finishAccountExit()
        }
        do {
            pendingAccountSetup?.suspend()
            await pendingAccountSetup?.drain()
            await runtimeLifecycle.prepareForAppErasure()
            let stored = try await erasingClient.listAccounts()
            for account in stored {
                _ = try? await erasingClient.marmot.clearPushRegistration(accountRef: account.label)
                conversationDraftStore.removeDrafts(accountRef: account.label)
            }
            await conversationDraftStore.flush(using: erasingClient)
            for account in stored {
                // Local removal also handles retained signed-out and unfinished profiles.
                try await erasingClient.marmot.removeAccount(accountRef: account.label)
                ChatMuteStore.clearAll(accountIdHex: account.accountIdHex)
                MessageHideStore.clearAll(accountRef: account.label)
                profileStore.clearContactNicknames(ownerAccountIdHex: account.accountIdHex)
            }
            guard try await erasingClient.listAccounts().isEmpty else {
                throw ForegroundRuntimeMutationError.runtimeUnavailable
            }
            try await runtimeLifecycle.closeForAppErasure()
            await RemoteAvatarImageLoader.clearCachesAndDrain()
            await GroupAvatarImageLoader.clearCachesAndDrain()
            let root = URL(fileURLWithPath: erasingClient.rootPath, isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                try AppDataErasure.eraseClosedRuntime(at: root)
                try AppDataErasure.clearContainerFiles()
            }.value
            guard await NotificationCommunicationDecorator.deleteAllDonatedInteractions() else {
                throw ForegroundRuntimeMutationError.runtimeUnavailable
            }
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            URLCache.shared.removeAllCachedResponses()
            RemoteAvatarImageLoader.clearCaches()
            GroupAvatarImageLoader.clearCaches()
            profileStore.clearForSignOut()
            accountStore.accounts = []
            accountStore.resetSelection()
            accountSetupSnapshots = []
            onboardingRecoveryAccounts = []
            pendingAccountSetup = nil
            isAccountSetupPresented = false
            pendingWipeReport = nil
            navigation.clearPendingProfile()
            navigation.clearPendingChat()
            accountUnreadStore.pruneToCurrentAccounts([])
            scheduleApplicationBadgeSynchronization()
            developerMode = false
            streamingDebugMode = false
            blockScreenshots = false
            resetQuickReactions()
            await appLock.setEnabled(false)
            appLock.gracePeriod = .immediate
            MediaAutoDownloadStore.shared.resetToDefaults()
            MediaQualityStore.setQuality(.standard)
            RemoteGIFLoadingStore.shared.setAutomaticallyLoads(false)
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)?
                .removePersistentDomain(forName: AppContainerConfig.appGroupIdentifier)
            signInAttempts.reset()
            diagnosticsConsent.reset()
            erasureState.complete()
            appDataErasureGeneration += 1
            isErasingAppData = false
            finishAccountExit()
            await bootstrap()
        } catch {
            isErasingAppData = false
            finishAccountExit()
            await bootstrap()
            erasureState.failed()
            present(.error(L10n.string("Erasure didn’t finish. Some data may remain. Try again.")))
            throw error
        }
    }

    @MainActor
    private func restoreNativePushAfterFailedSignOut(
        using client: MarmotClient,
        accountRef: String,
        wasEnabled: Bool
    ) async {
        guard wasEnabled else { return }
        _ = try? await client.marmot.setNativePushEnabled(accountRef: accountRef, enabled: true)
        finishAccountExit()
        scheduleNativePushRegistrationIfEnabled()
    }

    var isAccountExitInProgress: Bool { isSigningOut }

    /// Background suspension terminal-closes the shared runtime before waiting
    /// here. Account exit retains its captured, now-spent client and finishes
    /// with a typed storage error instead of reopening or trapping on globals.
    @MainActor
    func waitForAccountExitToFinish() async {
        guard isSigningOut else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            accountExitWaiters[id] = continuation
        }
    }

    @MainActor
    private func finishAccountExit() {
        guard isSigningOut else { return }
        isSigningOut = false
        let waiters = Array(accountExitWaiters.values)
        accountExitWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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

    /// Cancels and drains the native-push registration task. The task itself is
    /// owned by `NotificationCoordinator` (master #401); this internal wrapper
    /// lets `RuntimeLifecycle.releaseRuntimeAfterStartupFailure` /
    /// `cancelForegroundMaintenance` drain it without reaching into the
    /// coordinator directly. Also called by `signOut()`.
    func cancelNativePushRegistrationTask() async {
        await notificationCoordinator.cancelNativePushRegistrationTask()
    }

    /// Synchronously cancels the in-flight native-push registration task without
    /// awaiting it. Wraps `NotificationCoordinator` for the scene-phase entry
    /// points in `RuntimeLifecycle` (`setAppSceneActive`,
    /// `startRuntimeSuspension`); the drain-and-await happens later in
    /// `cancelForegroundMaintenance`.
    func cancelNativePushRegistrationTaskSync() {
        notificationCoordinator.cancelNativePushRegistrationTaskWithoutAwaiting()
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
        guard let client = foregroundSettingsReadClient() else { return .emptyDocument }
        return await client.parseMarkdown(text: text)
    }

    @MainActor
    @discardableResult
    func setRelayTelemetryExportEnabled(_ enabled: Bool) async throws -> RelayTelemetrySettingsFfi {
        guard phase == .ready else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
        _ = try await saveUsageDiagnosticsConsent(enabled)
        guard let client else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
        return try await client.relayTelemetrySettings()
    }

    func auditLogSettings() async throws -> AuditLogSettingsFfi? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditLogSettings()
    }

    @MainActor
    @discardableResult
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi {
        guard phaseOwnsLiveRuntime else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        return try await lease.client.marmot.setAuditLogSettings(
            settings: AuditLogSettingsFfi(enabled: enabled)
        )
    }

    func auditLogFiles() async throws -> [AuditLogFileFfi]? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditLogFiles()
    }

    func auditLogFileRows() async throws -> [AuditFileRow]? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditFileRows()
    }

    func diagnosticLogExport() async throws -> String {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let files = try await lease.client.auditLogFiles()
        let paths = files.filter { $0.sizeBytes > 0 }.map(\.path)
        return try await Task.detached(priority: .userInitiated) { try DiagnosticLogExport.report(paths: paths) }.value
    }

    @MainActor
    func deleteAllAuditLogFiles() async throws {
        // Fail loudly when the runtime isn't ready (e.g. a suspend window). A
        // silent success-shaped return would let the UI clear the list and play
        // a success haptic while nothing was deleted, then the files reappear on
        // the next foreground reload — a false confirmation for a privacy action.
        guard phase == .ready else { throw AuditLogActionError.runtimeNotReady }
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let client = lease.client
        let files = try await client.auditLogFiles()
        for file in files {
            _ = try await client.marmot.deleteAuditLogFile(path: file.path)
        }
    }

    /// Foreground relay catch-up. Delegates to `NotificationCoordinator` (master
    /// #401), which owns the catch-up gate/in-flight flag. Internal (not
    /// `private`) so `RuntimeLifecycle`'s resume path can sequence it without
    /// duplicating the catch-up state.
    func catchUpAfterForegroundActivation() async {
        await notificationCoordinator.catchUpAfterForegroundActivation(host: self)
    }

    func scheduleConnectivityCatchUp(connectivityRestored: Bool = false) {
        notificationCoordinator.scheduleConnectivityCatchUp(
            host: self,
            connectivityRestored: connectivityRestored
        )
    }

    /// Scene-phase entry points. Owned by `RuntimeLifecycle`; these forwarders
    /// keep the `whitenoise_iosApp.swift` scene wiring and the test call sites
    /// (`appState.setAppSceneActive`/`startForegroundActivation`/
    /// `startRuntimeSuspension`) unchanged.
    func setAppSceneActive(_ active: Bool) {
        runtimeLifecycle.setAppSceneActive(active)
    }

    @discardableResult
    func startForegroundActivation() -> Task<Void, Never> {
        runtimeLifecycle.startForegroundActivation()
    }

    @discardableResult
    func startRuntimeSuspension() -> Task<Void, Never> {
        // Claim the live runtime before the lifecycle flips its foreground gate.
        // The suspension task waits for this mutation lease before closing
        // SQLCipher, so the final composer keystrokes cannot race teardown.
        let draftLease = try? runtimeLifecycle.beginForegroundRuntimeMutation()
        let runtimeSuspensionTask = runtimeLifecycle.startRuntimeSuspension()
        let conversationDraftStore = conversationDraftStore
        return Task { @MainActor in
            if let draftLease {
                defer { runtimeLifecycle.endForegroundRuntimeMutation(draftLease) }
                await conversationDraftStore.flush(using: draftLease.client)
            }
            await runtimeSuspensionTask.value
        }
    }

    /// Cancels the AppState-side foreground maintenance for the lifecycle
    /// suspension path: it cancels (without awaiting) the
    /// `NotificationCoordinator`-owned native-push registration task and the
    /// profile fetch queue, returning the now-cancelled profile task for
    /// `RuntimeLifecycle.cancelForegroundMaintenance` to drain. The native-push
    /// drain itself goes back through `cancelNativePushRegistrationTask()` so the
    /// task stays owned by `NotificationCoordinator` (master #401).
    @MainActor
    func beginForegroundMaintenanceCancellation() -> ForegroundMaintenanceTasks {
        pendingAccountSetup?.suspend()
        let notificationSubscription = stopNotificationSubscription()
        let connectivityCatchUp = notificationCoordinator.cancelConnectivityCatchUpWithoutAwaiting()
        notificationCoordinator.cancelNativePushRegistrationTaskWithoutAwaiting()
        retentionSweeper.cancelWithoutAwaiting()
        let mutationFollowups = cancelForegroundMutationFollowups()
        return ForegroundMaintenanceTasks(
            notificationSubscription: notificationSubscription,
            connectivityCatchUp: connectivityCatchUp,
            profileRefresh: pauseProfileFetchQueue(),
            mutationFollowups: mutationFollowups
        )
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

    /// Internal (not `private`) so `RuntimeLifecycle.performBootstrap` can drive
    /// the account refresh once the runtime is online. The account refresh
    /// itself stays on AppState (it is account/profile maintenance, not
    /// lifecycle).
    @MainActor
    func refreshAccounts(refreshUnreadSummaries: Bool = true) async throws {
#if DEBUG
        try await beforeAccountRefreshForTesting?()
#endif
        let setupAtReadStart = pendingAccountSetup
        let attemptRevision = signInAttempts.revision
        let client = try runtimeClient()
        let localAccounts = try await client.listAccounts()
        var readyAccounts: [AccountSummaryFfi] = []
        var unfinished: [OnboardingSnapshotFfi] = []
        var recoveryAccounts: [AccountSummaryFfi] = []
        var currentSetupSnapshot: OnboardingSnapshotFfi?
        for account in localAccounts {
            try Task.checkCancellation()
            let snapshot: OnboardingSnapshotFfi?
            do {
                if try await client.onboardingRecoveryRequired(accountRef: account.accountIdHex) {
                    recoveryAccounts.append(account)
                    continue
                }
                snapshot = try await readOnboardingSnapshot(client: client, accountID: account.accountIdHex)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MarmotKitError where error.isTransientStartupReadinessFailure {
                throw error
            } catch {
                // An unreadable checkpoint gates its identity, not other local accounts.
                Self.accountRefreshLog.error("onboarding_snapshot_read_failed")
                continue
            }
            if snapshot?.accountIdHex == setupAtReadStart?.accountID { currentSetupSnapshot = snapshot }
            if let snapshot, !snapshot.ready || snapshot.cancellationPending || signInAttempts.accountIDs.contains(account.accountIdHex) {
                unfinished.append(snapshot)
            } else {
                readyAccounts.append(account)
            }
        }
        try Task.checkCancellation()
        guard self.client === client else { throw CancellationError() }
        // An older account read must not discard a sign-in begun while it awaited storage.
        guard pendingAccountSetup === setupAtReadStart, signInAttempts.revision == attemptRevision else { return }
        // Stage the usable accounts; neither guess readiness nor synthesize missing checkpoints.
        accountStore.accounts = readyAccounts
        if let activeAccountRef, !readyAccounts.contains(where: { $0.label == activeAccountRef }) {
            self.activeAccountRef = nil
        }
        accountSetupSnapshots = unfinished
        onboardingRecoveryAccounts = recoveryAccounts
        if let current = pendingAccountSetup {
            if let currentSetupSnapshot {
                current.apply(currentSetupSnapshot)
            } else {
                current.suspend()
                await current.drain()
                if pendingAccountSetup === current { pendingAccountSetup = nil }
            }
        }
        if pendingAccountSetup == nil, accounts.contains(where: { !$0.signedOut }), phase == .onboarding, !isFinishingAccountSetup {
            phase = .ready
        }
        if refreshUnreadSummaries {
            await refreshAccountUnreadSummaries()
        }
        updateProfileProjectionLocalAccountLabels()
        warmLocalAccountProfileProjections()
    }

    private func readOnboardingSnapshot(client: MarmotClient, accountID: String) async throws -> OnboardingSnapshotFfi? {
#if DEBUG
        try await beforeOnboardingSnapshotReadForTesting?(accountID)
#endif
        return try await client.onboardingSnapshot(accountID: accountID)
    }

    @ObservationIgnored private var unreadSummaryRefreshGeneration = 0
    /// Tracked so suspension can drain an in-flight badge refresh before the
    /// runtime shuts down; an escaping task could otherwise hold the FFI
    /// handle mid-`accountUnreadSummary()` while terminal storage close runs.
    @ObservationIgnored private var unreadSummaryRefreshTask: Task<Void, Never>?
#if DEBUG
    @ObservationIgnored var beforeUnreadSummaryRefreshForTesting: (() async -> Void)?
#endif

    /// Fire-and-forget wrapper for foreground resume — background reads and
    /// notification actions can move the read cursor while the cached summary
    /// goes stale.
    @MainActor
    func scheduleAccountUnreadSummaryRefresh() {
        let previous = unreadSummaryRefreshTask
        unreadSummaryRefreshTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.refreshAccountUnreadSummaries()
        }
    }

    /// Awaited by `RuntimeLifecycle.cancelForegroundMaintenance` so no badge
    /// refresh FFI read is in flight when suspension releases the runtime.
    @MainActor
    func drainUnreadSummaryRefresh() async {
        let task = unreadSummaryRefreshTask
        unreadSummaryRefreshTask = nil
        await task?.value
    }

    /// Fetches the durable unread aggregate (client access is AppState's domain)
    /// and feeds it to the store; on failure prunes stale entries. Concurrent
    /// refreshes can complete out of order — only the newest may commit, so an
    /// older fetch can't overwrite fresher badge counts.
    @MainActor
    func refreshAccountUnreadSummaries(using leasedClient: MarmotClient? = nil) async {
        guard !accounts.isEmpty else {
            accountUnreadStore.refreshed(from: [], accounts: [])
            await synchronizeApplicationBadge()
            return
        }
#if DEBUG
        if let beforeUnreadSummaryRefreshForTesting {
            await beforeUnreadSummaryRefreshForTesting()
        }
#endif
        // A badge refresh has no foreground UI to update while the durable
        // runtime is down, so it must never resurrect it: opening a suspended
        // runtime in the background would strand a durable `.advance` runtime
        // holding the App Group SQLite lock (`0xdead10cc`). Foreground callers
        // have a live `client`; a notification action passes its leased runtime.
        // With neither, degrade to a no-op.
        guard let summaryClient = leasedClient ?? client else { return }
        unreadSummaryRefreshGeneration += 1
        let generation = unreadSummaryRefreshGeneration
        let incrementalBaseline = accountUnreadStore.incrementalRevisionSnapshot()
        do {
            let summaries = try await summaryClient.accountUnreadSummaries()
            guard generation == unreadSummaryRefreshGeneration else { return }
            accountUnreadStore.refreshed(
                from: summaries,
                accounts: accounts,
                preservingUpdatesAfter: incrementalBaseline
            )
            await synchronizeApplicationBadge()
        } catch {
            guard generation == unreadSummaryRefreshGeneration else { return }
            accountUnreadStore.pruneToCurrentAccounts(accounts)
            await synchronizeApplicationBadge()
        }
    }

    @MainActor
    func accountUnreadSummary(forAccountIdHex accountIdHex: String) -> AccountUnreadFfi? {
        accountUnreadStore.summary(forAccountIdHex: accountIdHex)
    }

    @MainActor
    func accountUnreadBadgeCount(forAccountIdHex accountIdHex: String) -> UInt64? {
        accountUnreadStore.badgeCount(forAccountIdHex: accountIdHex)
    }

    @MainActor
    func updateAccountUnreadSummary(
        accountIdHex: String,
        chatListRows: [ChatListRowFfi]
    ) {
        accountUnreadStore.update(accountIdHex: accountIdHex, chatListRows: chatListRows, accounts: accounts)
        scheduleApplicationBadgeSynchronization()
    }

    @MainActor
    private func applicationBadgeCount() -> Int {
        accountUnreadStore.applicationBadgeCount()
    }

    @MainActor
    private func scheduleApplicationBadgeSynchronization() {
        notifications.scheduleApplicationBadgeCount(applicationBadgeCount())
    }

    @MainActor
    private func synchronizeApplicationBadge() async {
        await notifications.setApplicationBadgeCount(applicationBadgeCount())
    }

    // MARK: - Identity management

    /// Generate a fresh Nostr identity. On success the new account becomes active.
    /// Marmot owns the default profile pseudonym pool; iOS must not mirror it.
    @MainActor
    @discardableResult
    func createIdentity() async throws -> AccountSummaryFfi {
        let creation = try await createIdentityForProfileSetup()
        await completeIdentityProfileSetup(creation.account)
        return creation.account
    }

    /// Creates the durable identity without routing out of onboarding. The
    /// sign-up profile flow uses the returned account to publish optional
    /// metadata, then calls `completeIdentityProfileSetup` exactly once.
    @MainActor
    func createIdentityForProfileSetup() async throws -> IdentityCreationResultFfi {
        let ticket = productAnalytics.ticket()
        productOnboardingTicket = ticket
        productAnalytics.record(.onboarding(.identitySelection, .create, .success), ticket: ticket)
        var created = false
        defer { if !created { productAnalytics.record(.onboarding(.localReady, .create, .failure), ticket: ticket) } }
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let relays = MarmotClient.seedRelays
        let existingAccountLabels = Set(accounts.map(\.label))
        let creation = try await lease.client.marmot.createIdentityWithProfile(
            defaultRelays: relays,
            bootstrapRelays: relays
        )
        // MDK deliberately coalesces generated-identity calls while an earlier
        // account is still publishing. Never let a second-account flow edit or
        // activate that already-existing identity as though it were new.
        guard !existingAccountLabels.contains(creation.account.label) else {
            throw MarmotKitError.AccountSetupRetryRequired
        }
        created = true
        productAnalytics.record(.onboarding(.localReady, .create, .success), ticket: ticket)
        productAnalytics.record(.onboarding(.networkReady, .create, creation.readiness == .networkReady ? .success : .pending), ticket: ticket)
        pendingAccountSetupReadiness[creation.account.label] = creation.readiness
        return creation
    }

    @MainActor
    func completeIdentityProfileSetup(_ summary: AccountSummaryFfi) async {
        await productAnalytics.record(.onboarding(.complete, .create, .success), ticket: productOnboardingTicket)?.value
        productOnboardingTicket = nil
        productOnboardingPath = nil
        await activateNewIdentity(summary)
        if let readiness = pendingAccountSetupReadiness.removeValue(forKey: summary.label),
           readiness != .networkReady {
            present(.success(
                L10n.string("Account created"),
                message: L10n.string("Secure setup is finishing in the background.")
            ))
        }
    }

    /// Import an existing local-signing identity (nsec).
    @MainActor
    @discardableResult
    func importIdentity(_ identity: String) async throws -> AccountSummaryFfi {
        let ticket = productAnalytics.ticket()
        productOnboardingTicket = ticket
        productAnalytics.record(.onboarding(.identitySelection, .import, .success), ticket: ticket)
        var imported = false
        defer { if !imported { productAnalytics.record(.onboarding(.localReady, .import, .failure), ticket: ticket) } }
        let performance = HostActionPerformance.begin()
        let lease = try await runtimeLifecycle.beginUserInitiatedForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let relays = MarmotClient.seedRelays
        var snapshot: OnboardingSnapshotFfi
        do {
            let existing = try await lease.client.listAccounts()
            snapshot = try await lease.client.marmot.beginOnboarding(
                nsec: identity,
                options: OnboardingOptionsFfi(defaultRelays: relays, discoveryRelays: relays)
            )
            if !snapshot.ready, existing.contains(where: { $0.accountIdHex == snapshot.accountIdHex }) {
                snapshot = try await AccountSetupRecovery.restartIfPossible(
                    snapshot: snapshot,
                    cancel: { try await lease.client.marmot.cancelOnboarding(accountRef: snapshot.accountIdHex) },
                    begin: {
                        try await lease.client.marmot.beginOnboarding(
                            nsec: identity,
                            options: OnboardingOptionsFfi(defaultRelays: relays, discoveryRelays: relays)
                        )
                    }
                )
            }
        } catch MarmotKitError.OnboardingActionUnavailable {
            // Legacy active/pending accounts keep their existing recovery path.
            // MDK's login gate refuses an unfinished interactive checkpoint.
            let summary = try await lease.client.marmot.login(
                identity: identity, defaultRelays: relays, bootstrapRelays: relays
            )
            imported = true
            productAnalytics.record(.onboarding(.localReady, .import, .success), ticket: ticket)
            await productAnalytics.record(.onboarding(.complete, .import, .success), ticket: ticket)?.value
            productOnboardingPath = nil
            productOnboardingTicket = nil
            await activateNewIdentity(summary)
            HostActionPerformance.record("identity_import_to_ready", since: performance)
            return summary
        }
        let localAccounts = try await lease.client.listAccounts()
        guard let summary = localAccounts.first(where: { $0.accountIdHex == snapshot.accountIdHex }) else {
            throw MarmotKitError.OnboardingRequired
        }
        pendingAccountSetup?.suspend()
        await pendingAccountSetup?.drain()
        signInAttempts.begin(snapshot.accountIdHex)
        imported = true
        pendingAccountSetup = AccountSetupModel(snapshot: snapshot)
        pendingAccountSetup?.onProductReady = { [productAnalytics] in
            productAnalytics.record(.onboarding(.localReady, .import, .success), ticket: ticket)
            productAnalytics.record(.onboarding(.networkReady, .import, .success), ticket: ticket)
        }
        if pendingAccountSetup?.isDurablyReady == true { pendingAccountSetup?.onProductReady?() }
        accountSetupSnapshots.removeAll { $0.accountIdHex == snapshot.accountIdHex }
        accountSetupSnapshots.append(snapshot)
        isAccountSetupPresented = true
        HostActionPerformance.record("identity_import_to_setup", since: performance)
        return summary
    }

    /// Consent-gated compatibility recovery for imports stranded before MDK
    /// persisted resumable account-setup state. The caller must explain the
    /// possible orphaned KeyPackage before invoking this path.
    @MainActor
    @discardableResult
    func recoverIncompleteIdentity(_ identity: String) async throws -> AccountSummaryFfi {
        let ticket = productOnboardingTicket
        let performance = HostActionPerformance.begin()
        let lease = try await runtimeLifecycle.beginUserInitiatedForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let relays = MarmotClient.seedRelays
        let summary: AccountSummaryFfi
        do {
            summary = try await lease.client.marmot.loginRecoveringIncompleteSetup(
                nsec: identity,
                defaultRelays: relays,
                bootstrapRelays: relays,
                acknowledgePossibleKeyPackageOrphan: true
            )
        } catch let error as MarmotKitError {
            switch error {
            case .AccountSetupRetryRequired, .AccountSetupKeyPackageRecoveryAvailable:
                // The account became safely resumable between the original
                // failure and consent. Resume it without asking for the nsec
                // again or resetting recoverable KeyPackage material.
                summary = try await lease.client.marmot.login(
                    identity: identity,
                    defaultRelays: relays,
                    bootstrapRelays: relays
                )
            default:
                throw error
            }
        }
        productAnalytics.record(.onboarding(.localReady, .import, .success), ticket: ticket)
        await productAnalytics.record(.onboarding(.complete, .import, .success), ticket: ticket)?.value
        productOnboardingPath = nil
        productOnboardingTicket = nil
        await activateNewIdentity(summary)
        HostActionPerformance.record("identity_recovery_to_ready", since: performance)
        return summary
    }

    @MainActor
    private func activateNewIdentity(_ summary: AccountSummaryFfi) async {
        cacheActivatedAccountSummaryIfNeeded(summary)
        activeAccountRef = summary.label
        updateProfileProjectionLocalAccountLabels()
        warmProfileProjection(forAccountIdHex: summary.accountIdHex)
        completeOnboardingAfterIdentityActivation(scheduleNativePushRegistration: false)
        // A new identity can also be created from the `.ready` shell left by a
        // sign-out of every account; the onboarding completion above is a no-op
        // there, so the stopped maintenance loops need the same restart as
        // `activateAccount`.
        restartReadyForegroundMaintenanceIfStopped()
        scheduleNewIdentityMaintenance(summary)
    }

    @ObservationIgnored private var foregroundMutationFollowupTasks: [UUID: Task<Void, Never>] = [:]

    private func scheduleNewIdentityMaintenance(_ summary: AccountSummaryFfi) {
        scheduleForegroundMutationFollowup { [weak self] _ in
            guard let self else { return }
            try? await self.refreshAccounts(refreshUnreadSummaries: false)
            guard !Task.isCancelled else { return }
            self.scheduleAccountUnreadSummaryRefresh()
        }
        scheduleForegroundMutationFollowup { [weak self] _ in
            guard let self else { return }
            await self.enableNotificationsByDefault(for: summary.label)
            guard !Task.isCancelled else { return }
            self.scheduleNativePushRegistrationIfEnabled()
        }
    }

    func prewarmGroupMemberKeyPackages(
        memberRefs: [String]
    ) async throws -> MemberKeyPackagePrewarmSummaryFfi {
        guard let accountRef = activeAccountRef else {
            throw MarmotKitError.UnknownAccount(accountRef: "")
        }
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        return try await lease.client.prewarmGroupMemberKeyPackages(
            accountRef: accountRef,
            memberRefs: memberRefs
        )
    }

    private func scheduleForegroundMutationFollowup(
        operation: @escaping @MainActor (MarmotClient) async -> Void
    ) {
        guard let lease = try? runtimeLifecycle.beginForegroundRuntimeMutation() else { return }
        let id = UUID()
        let task = Task { @MainActor [self] in
            if !Task.isCancelled {
                await operation(lease.client)
            }
            finishForegroundMutationFollowup(id: id, lease: lease)
        }
        foregroundMutationFollowupTasks[id] = task
    }

    private func finishForegroundMutationFollowup(
        id: UUID,
        lease: ForegroundRuntimeMutationLease
    ) {
        foregroundMutationFollowupTasks.removeValue(forKey: id)
        runtimeLifecycle.endForegroundRuntimeMutation(lease)
    }

    private func cancelForegroundMutationFollowups() -> [Task<Void, Never>] {
        let tasks = Array(foregroundMutationFollowupTasks.values)
        tasks.forEach { $0.cancel() }
        return tasks
    }

    @MainActor
    private func cacheActivatedAccountSummaryIfNeeded(_ summary: AccountSummaryFfi) {
        guard !accountStore.accounts.contains(where: { $0.label == summary.label }) else { return }
        accountStore.accounts.append(summary)
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
        let client = try currentMarmotClient()
        return try await client.marmot.startAgentTextStream(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            streamIdHex: streamIdHex,
            quicCandidates: Self.agentTextStreamQuicCandidates
        )
    }

    #if DEBUG
    @ObservationIgnored var afterAccountExitClientCapturedForTesting: (() async -> Void)?

    @MainActor
    func scheduleForegroundMutationFollowupForTesting(
        operation: @escaping @MainActor () async -> Void
    ) {
        scheduleForegroundMutationFollowup { _ in
            await operation()
        }
    }

    /// Drives the suspend/resume lifecycle tasks to quiescence so tests can
    /// drive the real scene-phase entry points (`startRuntimeSuspension` /
    /// `startForegroundActivation`) and then await the terminal state. Forwards
    /// to `RuntimeLifecycle` (which owns the suspension/foreground tasks) and
    /// drains the AppState-owned native-push task last.
    @MainActor
    func drainRuntimeLifecycleTasksForTesting() async {
        await runtimeLifecycle.drainRuntimeLifecycleTasksForTesting()
        let followups = Array(foregroundMutationFollowupTasks.values)
        for task in followups {
            await task.value
        }
        await notificationCoordinator.drainNativePushRegistrationTaskForTesting()
    }

    /// Drains the in-flight native-push registration task so
    /// `RuntimeLifecycle.drainRuntimeLifecycleTasksForTesting` can flush the
    /// `NotificationCoordinator`-owned task as the last step of the lifecycle
    /// chain.
    @MainActor
    func nativePushRegistrationTaskValueForTesting() async {
        await notificationCoordinator.drainNativePushRegistrationTaskForTesting()
    }

    /// Exposes the sign-out teardown guard (#320) so tests can assert it is
    /// raised only during `signOut()` and cleared before the function returns
    /// (so a legitimate post-sign-out reschedule is not suppressed).
    @MainActor
    var isSigningOutForTesting: Bool { isSigningOut }

    var retentionSweeperIsActiveForTesting: Bool { retentionSweeper.isSweeping }

    var hasPendingUnreadSummaryRefreshForTesting: Bool { unreadSummaryRefreshTask != nil }
    #endif
}

extension AppState: NotificationCoordinatorHost {
    func configureNotifications() {
        notifications.configure(appState: self)
    }

    var isRuntimeSuspendingForNotificationCoordinator: Bool { isRuntimeSuspending }
    var isSigningOutForNotificationCoordinator: Bool { isSigningOut }
}
