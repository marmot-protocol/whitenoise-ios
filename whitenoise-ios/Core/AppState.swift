// swiftlint:disable no_test_hook_in_app_code
import Combine
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

    /// True while the runtime itself is live and usable (not suspended for
    /// background and not shutting down), independent of transient `.inactive`
    /// focus loss such as Face ID, Control Center, Notification Center, or the
    /// App Switcher.
    static func canUseLiveRuntime(
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool,
        hasRuntimeClient: Bool
    ) -> Bool {
        !runtimeSuspendedForBackground
            && !isRuntimeSuspending
            && hasRuntimeClient
    }

    /// True while runtime-backed UI subscriptions may remain active (not
    /// suspended for background and not shutting down), independent of
    /// transient `.inactive` focus loss.
    static func canUseLiveRuntimeWork(
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool
    ) -> Bool {
        !runtimeSuspendedForBackground
            && !isRuntimeSuspending
    }
}

struct ForegroundMaintenanceTasks {
    let notificationSubscription: Task<Void, Never>?
    let connectivityCatchUp: Task<Void, Never>?
    let profileRefresh: Task<Void, Never>?
    let mutationFollowups: [Task<Void, Never>]
}

/// The reads `refreshAccounts` stages before it changes account or setup routing.
nonisolated struct AccountRefreshReads: Sendable {
    var listAccounts: @MainActor (MarmotClient) async throws -> [AccountSummaryFfi]
    var onboardingSnapshot: @MainActor (MarmotClient, _ accountID: String) async throws -> OnboardingSnapshotFfi?

    static let live = AccountRefreshReads(
        listAccounts: { client in try await client.listAccounts() },
        onboardingSnapshot: { client, accountID in try await client.onboardingSnapshot(accountID: accountID) }
    )
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
    /// Device preferences (developer mode, screenshots, reactions). `.standard`
    /// in production; tests inject an isolated suite.
    @ObservationIgnored private let preferenceDefaults: UserDefaults
    var accounts: [AccountSummaryFfi] { accountStore.accounts }

    private(set) var isErasingAppData = false
    var appDataErasureGeneration = 0
    var openSettingsAfterProfileSelection = false
    let erasureState: AppDataErasureState
    let signInAttempts: SignInAttemptStore
    let nativePushRestoreIntents: NativePushRestoreIntents
    var productContextRevision = UUID()
    var productConsentMutationInProgress = false
    var productOnboardingPath: ProductOnboardingPath?
    var productOnboardingTicket: ProductAnalyticsRecorder.Ticket?
    let productAnalytics = ProductAnalyticsRecorder()
    @ObservationIgnored var conversationOpenPerformance: ConversationOpenPerformance?
    var pendingProductActivity: ProductAnalyticsActivityFfi = .foreground
    let diagnosticsConsent: DeviceDiagnosticsConsent
    var pendingAccountSetup: AccountSetupModel?
    private(set) var accountSetupSnapshots: [OnboardingSnapshotFfi] = []
    private(set) var onboardingRecoveryAccounts: [AccountSummaryFfi] = []
    var isAccountSetupPresented = false
    private(set) var isFinishingAccountSetup = false
    private static let accountRefreshLog = Logger(subsystem: "dev.ipf.whitenoise", category: "account-refresh")
    @ObservationIgnored private let accountRefreshReads: AccountRefreshReads

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
            model.failure = .closeSignIn
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
        let id = model.accountID
        signInAttempts.finish(id)
        model.suspend()
        await model.drain()
        pendingAccountSetup = nil
        isAccountSetupPresented = false
        do {
            try await refreshAccounts(refreshUnreadSummaries: false)
            guard let summary = accounts.first(where: { $0.accountIdHex == id }) else {
                // Refresh can exclude an unreadable checkpoint without failing the other accounts.
                throw MarmotKitError.AccountSetupRetryRequired
            }
            await productAnalytics.record(.onboarding(.complete, .import, .success), ticket: productOnboardingTicket)?.value
            productOnboardingTicket = nil
            productOnboardingPath = nil
            guard !blocksAccountWork else { return }
            await activateNewIdentity(summary)
            deviceLinks.noteSetupFinished(accountIdHex: id)
        } catch {
            signInAttempts.begin(id)
            pendingAccountSetup = model
            isAccountSetupPresented = true
            model.failure = .refreshAccounts
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
            HostSettingsSaveTiming.measure { preferenceDefaults.set(developerMode, forKey: Self.developerModeKey) }
        }
    }

    /// When developer mode is on, show non-chat MLS events (reactions, deletes,
    /// edits, agent and unknown kinds) in the conversation timeline with debug
    /// styling.
    var streamingDebugMode: Bool {
        didSet {
            HostSettingsSaveTiming.measure { preferenceDefaults.set(streamingDebugMode, forKey: Self.streamingDebugModeKey) }
        }
    }

    /// Device-wide opt-in for MDK's native startup diagnostics. Applied to the
    /// running runtime immediately and to future runtimes before account reads.
    /// Disabling clears captured history.
    var startupDiagnosticsEnabled: Bool {
        didSet {
            StartupDiagnosticsPreference.setEnabled(startupDiagnosticsEnabled, preferenceDefaults)
            try? client?.marmot.setStartupDiagnosticsEnabled(enabled: startupDiagnosticsEnabled)
        }
    }

    /// Effective chat-debug flag: requires developer mode.
    var streamingDebugEnabled: Bool {
        developerMode && streamingDebugMode
    }

    /// Blocks screenshots and screen recordings of app content while on
    /// (window-level capture exclusion, applied by `WindowCaptureProtection`).
    /// Off by default; toggled in Settings → Privacy & Security.
    var blockScreenshots: Bool {
        didSet {
            HostSettingsSaveTiming.measure { preferenceDefaults.set(blockScreenshots, forKey: Self.blockScreenshotsKey) }
        }
    }

    /// Recently-used reaction emojis, most-recent first. Drives the quick row
    /// in the message actions overlay.
    private(set) var recentReactions: [String]
    private(set) var customizedQuickReactions: [String]?

    nonisolated static let defaultReactions = ["❤️", "🤘", "🔥", "😂", "🦫", "🚀"]

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
        preferenceDefaults.set(recentReactions, forKey: Self.recentReactionsKey)
    }

    func setQuickReactions(_ choices: [String]) {
        let normalized = QuickReactionPreferences.save(choices, to: preferenceDefaults)
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

    /// IPF moderation reports are configured per build flavor. Unconfigured
    /// builds hide every report-to-White-Noise affordance.
    var moderationReportingAvailable: Bool {
        moderationReportingAvailability(client)
    }
    @ObservationIgnored private let moderationReportingAvailability: @MainActor (MarmotClient?) -> Bool

    nonisolated static func moderationReportingAvailable(on client: MarmotClient?) -> Bool {
        client?.moderationReportingAvailable == true
    }

    /// Launch-to-root-surface timing, held until the first runtime can record it.
    @ObservationIgnored var hostWindowInitStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var pendingHostWindowInitMilliseconds: UInt64?

    func noteHostWindowInitialized() {
        guard let startedAt = hostWindowInitStartedAt else { return }
        hostWindowInitStartedAt = nil
        pendingHostWindowInitMilliseconds = ProductAnalyticsRecorder.elapsedMilliseconds(from: startedAt, to: .now)
    }

    func flushHostWindowInit(to client: MarmotClient) {
        guard let milliseconds = pendingHostWindowInitMilliseconds else { return }
        pendingHostWindowInitMilliseconds = nil
        client.recordHostPerformance(operation: .windowInit, durationMs: milliseconds, outcome: .success)
    }
    let notifications: AppNotifications
    @ObservationIgnored let notificationCoordinator: NotificationCoordinator
    let appReviewDemo = AppReviewDemoCoordinator()
    let toastState = ToastState()
    let navigation = NavigationState()
    /// Invalidates rendered Markdown timestamps; see `MarkdownTimestampRenderClock`.
    let markdownTimestampClock = MarkdownTimestampRenderClock()
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
    @ObservationIgnored let signUpDraftStore: SignUpDraftStore
    @ObservationIgnored var hasRestoredSignUp = false
    @ObservationIgnored var signUpRestorationTask: Task<Void, Error>?
    var signUpModel = CreateIdentityViewModel()
    var restoreSignUpPresentation = false

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
    /// True only when a UI scene has actually reported `.active`, distinguishing
    /// a visible foreground app from a cold UI-less launch where
    /// `isAppSceneActive` still holds its optimistic initial `true`.
    var hasReportedActiveScene: Bool { sceneHasReportedPhase && isAppSceneActive }
    private(set) var profileRefreshGeneration = 0

    /// Foreground expiration-sweep loop for disappearing messages. Started
    /// with the other `.ready` foreground maintenance and cancelled on
    /// background suspension.
    @ObservationIgnored private let retentionSweeper: MessageRetentionSweeper
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

    /// True while full app-data erasure is running or an unfinished erasure
    /// must keep surviving accounts out of activation, routing, maintenance,
    /// sign-up restoration, and notification actions until erasure completes.
    var blocksAccountWork: Bool {
        isErasingAppData || erasureState.blocksNormalAccountActivation
    }

    var runtimeEventsGeneration: Int? {
        guard phaseOwnsLiveRuntime,
              !runtimeSuspendedForBackground,
              !isRuntimeSuspending,
              !blocksAccountWork,
              client != nil else { return nil }
        return runtimeGeneration
    }

    func observeRuntimeEvents() async {
        guard let generation = runtimeEventsGeneration, let client else { return }
        let events = SubscriptionDriver.events(client.subscribeEvents())
        // A rewind restore can fail while accounts open, before this subscription
        // exists, and events don't replay; MDK's quarantine list still has it.
        // Read it in this task (the stream buffers meanwhile), so the reads stop
        // with the runtime instead of overlapping its storage closure.
        for account in accounts where !account.signedOut {
            guard !Task.isCancelled, runtimeEventsGeneration == generation else { return }
            guard let groups = try? await client.quarantinedGroups(accountRef: account.accountIdHex) else { continue }
            for event in GroupChangeNotice.rewindRestoreEvents(account: account, quarantined: groups) {
                handleRuntimeEvent(event, generation: generation)
            }
        }
        // One read per chat: run it beside live events so a launch burst can't
        // overflow the stream's buffer while it reads.
        let retainedScan = Task { await self.announceRetainedUndeliveredChange(client: client, generation: generation) }
        defer { retainedScan.cancel() }
        for await event in events {
            guard !Task.isCancelled, runtimeEventsGeneration == generation else { return }
            handleRuntimeEvent(event, generation: generation)
        }
    }

    /// A change MDK gave up while no subscription was listening (before
    /// launch) only notifies once, so read MDK's retained records, once per
    /// launch, and raise the newest; acknowledging it lets the next one show.
    private func announceRetainedUndeliveredChange(client: MarmotClient, generation: Int) async {
        guard !checkedRetainedUndeliveredChanges else { return }
        var newest: (event: MarmotEventFfi, at: UInt64)?
        var readEverything = true
        for account in accounts where !account.signedOut {
            guard let rows = try? await client.chatList(accountRef: account.accountIdHex, includeArchived: true) else {
                readEverything = false
                continue
            }
            for row in rows {
                guard !Task.isCancelled, runtimeEventsGeneration == generation else { return }
                guard let records = try? await client.marmot.groupChangesNotDelivered(
                    accountRef: account.accountIdHex, groupIdHex: row.groupIdHex
                ) else {
                    readEverything = false
                    continue
                }
                guard let event = GroupChangeNotice.retainedNotDeliveredEvent(account: account, records: records),
                      let at = records.map(\.at).max(), newest.map({ at > $0.at }) ?? true else { continue }
                newest = (event, at)
            }
        }
        // An interrupted scan, or one with a failed read, runs again with the
        // next runtime; raising the newest acknowledges it, so it won't repeat.
        guard !Task.isCancelled, runtimeEventsGeneration == generation else { return }
        checkedRetainedUndeliveredChanges = readEverything
        if let newest { handleRuntimeEvent(newest.event, generation: generation) }
    }

    @ObservationIgnored private var checkedRetainedUndeliveredChanges = false

    var groupRecoveryUpdate: GroupRecoveryUpdate?
    var groupMembershipUpdate: GroupRecoveryUpdate?
    var groupProjectionUpdate: GroupRecoveryUpdate?
    let historyNotices = HistoryNoticeStore()
    /// Linked devices and device linking for the active account.
    let deviceLinks = DeviceLinkStore()
    @ObservationIgnored private var refusedIntentAnnouncements = RefusedIntentAnnouncements()
    /// The active account's NIP-51 emoji sets, shared by every chat so typed
    /// `:shortcode:` resolves without opening a picker.
    @ObservationIgnored lazy var emojiSetLibrary = EmojiSetLibrary(
        scopeProvider: { [weak self] in
            guard let self, let account = self.activeAccountRef else { return nil }
            return EmojiSetScope(accountRef: account, runtimeGeneration: self.runtimeGeneration)
        },
        calls: .live { [weak self] in
            guard let self else { throw CancellationError() }
            return try self.currentMarmotClient()
        }
    )
    /// Visible attachment collections subscribe independently to off-window changes.
    let attachmentProjectionUpdates = PassthroughSubject<RuntimeProjectionUpdateFfi, Never>()
    let pollVotesInvalidation = PollVotesInvalidation()
    // Review is a separate destination; timeline visibility ends when it is pushed.
    @ObservationIgnored var moderationProjectionRoute: GroupRecoveryUpdate?

    struct GroupRecoveryUpdate: Equatable {
        let accountID: String
        let groupID: String
        let id = UUID()
    }

    func handleRuntimeEvent(_ event: MarmotEventFfi, generation: Int) {
        guard runtimeEventsGeneration == generation else { return }
        if case .projectionUpdated(let update) = event { attachmentProjectionUpdates.send(update) }
        pollVotesInvalidation.observe(event)
        if case .projectionUpdated(let update) = event,
           activeAccount?.accountIdHex == update.accountIdHex,
           moderationProjectionRoute?.accountID == update.accountIdHex,
           moderationProjectionRoute?.groupID == update.update.groupIdHex {
            groupProjectionUpdate = GroupRecoveryUpdate(accountID: update.accountIdHex, groupID: update.update.groupIdHex)
        }
        if case .groupStateUpdated(let accountID, _, let groupID) = event,
           activeAccount?.accountIdHex == accountID,
           visibleChat?.groupIdHex == groupID {
            groupRecoveryUpdate = GroupRecoveryUpdate(accountID: accountID, groupID: groupID)
        }
        // MDK applies device-local membership changes before delivering these
        // events and creates no system row. The group-record subscription can
        // deduplicate them, so the open conversation re-reads its snapshot
        // (membership) and recovery state directly.
        if case .groupEvent(let accountID, _, let groupID, let kind) = event,
           GroupEventPresentationPolicy.refreshesMembershipPresentation(kind),
           activeAccount?.accountIdHex == accountID,
           visibleChat?.groupIdHex == groupID {
            groupMembershipUpdate = GroupRecoveryUpdate(accountID: accountID, groupID: groupID)
        }
        if case .historyNoticesChanged(let accountID, _) = event, activeAccount?.accountIdHex == accountID {
            Task { await historyNotices.refresh(using: self) }
        }
        deviceLinks.observe(event, using: self)
        let noticeAccountID: String
        switch event {
        case .groupChangeSuperseded(let accountID, _, _, _, _, _, _):
            noticeAccountID = accountID
        case .groupEvent(let accountID, _, _, .queuedIntentRefused),
             .groupEvent(let accountID, _, _, .groupChangeNotDelivered),
             .groupEvent(let accountID, _, _, .groupHydrationQuarantined(.rewindRestoreFailed)):
            noticeAccountID = accountID
        default:
            return
        }
        guard runtimeEventsGeneration == generation,
              accounts.contains(where: { $0.accountIdHex == noticeAccountID && !$0.signedOut }),
              let notice = GroupChangeNotice.toast(for: event),
              refusedIntentAnnouncements.admit(event) else { return }
        present(notice)
        // MDK keeps a given-up change until the user has seen it.
        if case .groupEvent(let accountID, _, let groupID, .groupChangeNotDelivered(let commitID, _, _)) = event,
           let client = try? currentMarmotClient() {
            Task {
                _ = try? await client.marmot.acknowledgeChangeNotDelivered(
                    accountRef: accountID, groupIdHex: groupID, commitIdHex: commitID
                )
            }
        }
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
    var canUseLiveRuntime: Bool { runtimeLifecycle.canUseLiveRuntime }
    var canUseLiveRuntimeWork: Bool { runtimeLifecycle.canUseLiveRuntimeWork }
    var isCurrentClientStarted: Bool { runtimeLifecycle.isCurrentClientStarted }

    private static let developerModeKey = "marmot.developerMode"
    private static let streamingDebugModeKey = "marmot.streamingDebugMode"
    private static let blockScreenshotsKey = "marmot.blockScreenshots"
    private static let recentReactionsKey = "marmot.recentReactions"
    private static let defaultSuspendedRuntimeTelemetryBuildConfig = TelemetryBuildConfig.current()

    init(
        client: MarmotClient?,
        notifications: AppNotifications,
        conversationDraftStore: ConversationDraftStore? = nil,
        signUpDraftStore: SignUpDraftStore? = nil,
        accountDefaults: UserDefaults = .standard,
        // Default arguments evaluate in a nonisolated context and `UserDefaults`
        // is not Sendable, so the MainActor store is resolved in the body.
        erasureDefaults: UserDefaults? = nil,
        preferenceDefaults: UserDefaults? = nil,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig = AppState.defaultSuspendedRuntimeTelemetryBuildConfig,
        runtimeClientFactory: @escaping RuntimeLifecycle.RuntimeClientFactory =
            RuntimeLifecycle.defaultRuntimeClientFactory,
        runtimeStarter: @escaping RuntimeLifecycle.RuntimeStarter =
            RuntimeLifecycle.defaultRuntimeStarter,
        runtimeCloser: @escaping RuntimeLifecycle.RuntimeCloser =
            RuntimeLifecycle.defaultRuntimeCloser,
        runtimeRetrySleeper: @escaping RuntimeLifecycle.RetrySleeper = {
            delay in try await Task.sleep(for: delay)
        },
        runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy = .foreground,
        mutationDrainSleeper: @escaping RuntimeLifecycle.RetrySleeper = {
            delay in try await Task.sleep(for: delay)
        },
        notificationCatchUpCalls: NotificationCatchUpCalls = .live,
        hostPerformanceRecorder: @escaping RuntimeLifecycle.HostPerformanceRecorder =
            RuntimeLifecycle.recordHostPerformanceOnClient,
        moderationReportingAvailability: @escaping @MainActor (MarmotClient?) -> Bool = AppState.moderationReportingAvailable(on:),
        retentionSweepSleep: @escaping MessageRetentionSweeper.Sleep = MessageRetentionSweeper.taskSleep,
        accountRefreshReads: AccountRefreshReads = .live
    ) {
        self.moderationReportingAvailability = moderationReportingAvailability
        self.accountRefreshReads = accountRefreshReads
        self.retentionSweeper = MessageRetentionSweeper(sleep: retentionSweepSleep)
        self.notificationCoordinator = NotificationCoordinator(catchUpCalls: notificationCatchUpCalls)
        self.runtimeLifecycle = RuntimeLifecycle(
            client: client,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig,
            runtimeClientFactory: runtimeClientFactory,
            runtimeStarter: runtimeStarter,
            runtimeCloser: runtimeCloser,
            retrySleeper: runtimeRetrySleeper,
            constructionRetryPolicy: runtimeConstructionRetryPolicy,
            mutationDrainSleeper: mutationDrainSleeper,
            hostPerformanceRecorder: hostPerformanceRecorder
        )
        self.accountStore = AccountStore(defaults: accountDefaults)
        self.notifications = notifications
        self.signUpDraftStore = signUpDraftStore ?? SignUpDraftStore()
        self.conversationDraftStore = conversationDraftStore ?? ConversationDraftStore()
        self.erasureState = AppDataErasureState(
            defaults: erasureDefaults ?? AppDataErasureState.persistentDefaults,
            legacyDefaults: accountDefaults)
        self.signInAttempts = SignInAttemptStore(defaults: accountDefaults)
        self.nativePushRestoreIntents = NativePushRestoreIntents(defaults: accountDefaults)
        self.diagnosticsConsent = DeviceDiagnosticsConsent()
        let preferenceDefaults = preferenceDefaults ?? .standard
        self.preferenceDefaults = preferenceDefaults
        self.developerMode = preferenceDefaults.bool(forKey: Self.developerModeKey)
        self.streamingDebugMode = preferenceDefaults.bool(forKey: Self.streamingDebugModeKey)
        self.startupDiagnosticsEnabled = StartupDiagnosticsPreference.isEnabled(preferenceDefaults)
        self.blockScreenshots = preferenceDefaults.bool(forKey: Self.blockScreenshotsKey)
        self.recentReactions = preferenceDefaults.stringArray(forKey: Self.recentReactionsKey)
            ?? Self.defaultReactions
        self.customizedQuickReactions = QuickReactionPreferences.load(from: preferenceDefaults)
        self.profileStore.appState = self
        self.runtimeLifecycle.configure(appState: self)
        self.conversationDraftStore.configure(persistence: self)
        self.appReviewDemo.configure(appState: self, defaults: accountDefaults)
    }

    convenience init(client: MarmotClient) {
        self.init(client: client, notifications: .shared)
    }

    deinit {
        attentionTask?.cancel()
        unreadSummaryRefreshTask?.cancel()
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
    func restartReadyForegroundMaintenanceIfStopped() {
        guard phase == .ready, !notificationCoordinator.notificationSubscriptionActive else { return }
        startReadyForegroundMaintenance(scheduleNativePushRegistration: false)
    }

    /// Internal (not `private`) so `RuntimeLifecycle.performBootstrap` can hand
    /// back the account-scoped maintenance once the runtime is ready.
    @MainActor
    func startReadyForegroundMaintenance(scheduleNativePushRegistration: Bool = true) {
        guard !blocksAccountWork else { return }
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
        guard !blocksAccountWork else { return }
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
        guard !blocksAccountWork else { return }
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
        let accountRef = activeAccountRef
        let settings = try await notificationCoordinator.setNativePushEnabled(enabled, host: self)
        // A newer explicit choice supersedes a rollback left by an interrupted exit.
        if let accountRef { nativePushRestoreIntents.clear(accountRef) }
        return settings
    }

    private func enableNotificationsByDefault(for accountRef: String) async {
        await notificationCoordinator.enableNotificationsByDefault(for: accountRef, host: self)
    }

    /// Switches the active account, signing it back in first when it was
    /// locally signed out without wiping.
    @MainActor
    func activateAccount(_ accountRef: String) async {
        guard !isSigningOut, !blocksAccountWork else { return }
        guard accountRef != activeAccountRef else { return }
        guard let account = accounts.first(where: { $0.label == accountRef }) else { return }
        guard activatingAccountRefs.insert(accountRef).inserted else { return }
        defer { activatingAccountRefs.remove(accountRef) }
        // The switch invalidates the product-analytics sink, so this stage goes
        // straight to the runtime like the other lifecycle stages.
        let switchStartedAt = ContinuousClock.now
        func recordSwitch(_ outcome: HostPerformanceOutcomeFfi) {
            client?.recordHostPerformance(
                operation: .accountSwitch,
                durationMs: ProductAnalyticsRecorder.elapsedMilliseconds(from: switchStartedAt, to: .now),
                outcome: outcome
            )
        }

        if account.signedOut {
            do {
                let activationClient = try currentMarmotClient()
                _ = try await activationClient.signInAccount(accountRef: accountRef)
                try await refreshAccounts()
            } catch {
                recordSwitch(error is CancellationError ? .cancelled : .failure)
                present(UserFacingError.toast(title: L10n.string("Couldn't sign in"), error: error))
                return
            }
        }

        guard !blocksAccountWork else {
            recordSwitch(.cancelled)
            return
        }
        guard accounts.contains(where: { $0.label == accountRef && !$0.signedOut }) else {
            recordSwitch(.unavailable)
            return
        }
        activeAccountRef = accountRef

        restartReadyForegroundMaintenanceIfStopped()
        scheduleNativePushRegistrationIfEnabled()
        recordSwitch(.success)
    }

    /// Keeps completed sign-out/cleanup issues visible after account routing
    /// removes the initiating screen. Hosted by `RootView`.
    var pendingWipeReport: WipeReport?

    /// Root-hosted presentation survives Settings disappearing during account exit.
    var accountExitIntent: AccountExitIntent?

    /// Non-destructively signs out of the active account: clears its native
    /// push registration, deactivates it in Marmot, and opens profile selection. The account row, keys, encrypted store, media,
    /// and drafts stay on device so the Profiles screen can sign it back in.
    ///
    /// Push cleanup is best-effort — a transient marmot error here must not
    /// block the user from signing out.
    @MainActor
    @discardableResult
    func signOut(onError: ((Toast) -> Void)? = nil) async -> Bool {
        guard let signingOut = activeAccountRef else { return false }
        guard AccountExitGate.canBegin(
            isReady: phase == .ready,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: client != nil
        ), !isSigningOut else {
            (onError ?? present)(.error(L10n.string("Couldn't sign out")))
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
        notifications.cancelForegroundBatches(accountRef: signingOut)
        defer { finishAccountExit() }
        guard let exitingClient = client else {
            (onError ?? present)(.error(L10n.string("Couldn't sign out")))
            return false
        }
        await awaitCancelledForegroundMutationFollowups()
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
        if nativePushWasEnabled { nativePushRestoreIntents.mark(signingOut) }
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
                (onError ?? present)(.error(L10n.string("Couldn't sign out"), message: message))
                return false
            }
        } catch {
            await restoreNativePushAfterFailedSignOut(
                using: exitingClient,
                accountRef: signingOut,
                wasEnabled: nativePushWasEnabled
            )
            (onError ?? present)(UserFacingError.toast(title: L10n.string("Couldn't sign out"), error: error))
            return false
        }

        nativePushRestoreIntents.clear(signingOut)
        let failures = await completeSignOut(
            removedRef: signingOut,
            removedAccountIdHex: signingOutAccountIdHex,
            destructive: false
        )
        if !failures.isEmpty {
            pendingWipeReport = WipeReport(stages: [
                WipeStageReport(stage: .wipingLocalData, completedCount: nil, failures: failures),
            ], didWipeData: false)
        }
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
        destructive: Bool,
        routesAway: Bool = true
    ) async -> [WipeFailureItem] {
        var localCleanupFailures: [WipeFailureItem] = []
        // Hold the avatar-cache erasure gate across disk cleanup, account
        // refresh, and routing so a still-displayed departing profile cannot
        // repopulate the cleared avatar cache while `refreshAccounts()` awaits.
        if destructive {
            AvatarCacheErasure.begin()
        }
        defer {
            if destructive {
                AvatarCacheErasure.end()
            }
        }
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
            let clearedInteractions = await NotificationCommunicationDecorator.deleteAllDonatedInteractions()
            let clearedNotificationAvatars = await Task.detached(priority: .utility) {
                NotificationCommunicationDecorator.clearAvatarCache()
            }.value
            if !clearedInteractions || !clearedNotificationAvatars {
                localCleanupFailures.append(WipeFailureItem(
                    subject: nil,
                    reason: L10n.string("Some notification previews may remain on this device."),
                    kind: .notificationPreviews
                ))
            }
            let clearedDecryptedMedia = await MessageMediaCache.purgeAllDecryptedMedia()
            await RemoteAvatarImageLoader.clearCachesAndDrain()
            await GroupAvatarImageLoader.clearCachesAndDrain()
            let clearedProfileAvatars = await RemoteAvatarDiskCache.shared.removeAll()
            let clearedGroupAvatars = await RemoteAvatarDiskCache.groupShared.removeAll()
            let clearedGroupThumbnails = await RemoteAvatarDiskCache.groupThumbnailShared.removeAll()
            if !clearedDecryptedMedia || !clearedProfileAvatars || !clearedGroupAvatars || !clearedGroupThumbnails {
                localCleanupFailures.append(WipeFailureItem(
                    subject: nil,
                    reason: L10n.string("Some decrypted media may remain on this device."),
                    kind: .decryptedMedia
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
            localCleanupFailures.append(WipeFailureItem(
                subject: nil,
                reason: UserFacingError.message(for: error),
                kind: .accountRefresh
            ))
        }

        if !routesAway {
            // Whichever profile is active stays; only this one's projections go.
            if let removedAccountIdHex {
                profileStore.clearForAccountRemoval(accountIdHex: removedAccountIdHex)
            }
        } else if !accounts.contains(where: { !$0.signedOut }) {
            accountStore.requestProfileSelection()
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
            accountStore.requestProfileSelection()
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
    func signOutAndWipeActiveAccount(onError: ((Toast) -> Void)? = nil) async -> Bool {
        guard let wipingRef = activeAccountRef else { return false }
        do {
            try await wipeActiveAccount(wipingRef)
            return true
        } catch ForegroundRuntimeMutationError.runtimeUnavailable {
            (onError ?? present)(.error(L10n.string("Couldn't wipe profile")))
        } catch let error as ProfileDataRemainsError {
            (onError ?? present)(.error(L10n.string("Couldn't wipe profile"), message: error.errorDescription))
        } catch {
            (onError ?? present)(UserFacingError.toast(title: L10n.string("Couldn't wipe profile"), error: error))
        }
        return false
    }

    /// Throws `runtimeUnavailable` when the wipe can't begin, or the wipe's error.
    @MainActor
    private func wipeActiveAccount(_ wipingRef: String, requiringUnlinked: Bool = false) async throws {
        guard DestructiveWipeGate.canBegin(
            isReady: phase == .ready,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: client != nil
        ), !isSigningOut else {
            throw ForegroundRuntimeMutationError.runtimeUnavailable
        }
        let wipingAccountIdHex = accounts
            .first(where: { $0.label == wipingRef })?
            .accountIdHex

        // Same #320 guard the normal sign-out uses: block any APNS-token-driven
        // push reschedule for the whole teardown; cleared before routing so a
        // reschedule for the *new* active account is not suppressed.
        isSigningOut = true
        notifications.cancelForegroundBatches(accountRef: wipingRef)
        defer { finishAccountExit() }
        guard let exitingClient = client else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
        if requiringUnlinked { _ = try await requireUnlinked(wipingRef, using: exitingClient) }
        await awaitCancelledForegroundMutationFollowups()
        try await wipeAccount(wipingRef, accountIdHex: wipingAccountIdHex, using: exitingClient, routesAway: true)
    }

    /// The wipe shared by Sign Out & Wipe and removing an unlinked profile:
    /// clears push the way sign-out does, wipes through MDK, then removes what
    /// the app keeps for that profile and reports anything left. Only
    /// `routesAway` leaves the active profile. The caller holds `isSigningOut`.
    /// Throws when nothing was removed, with push restored.
    @MainActor
    private func wipeAccount(
        _ wipingRef: String,
        accountIdHex wipingAccountIdHex: String?,
        using exitingClient: MarmotClient,
        routesAway: Bool
    ) async throws {
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
        if nativePushWasEnabled { nativePushRestoreIntents.mark(wipingRef) }
        _ = try? await exitingClient.marmot.clearPushRegistration(accountRef: wipingRef)
        _ = try? await exitingClient.marmot.setNativePushEnabled(accountRef: wipingRef, enabled: false)

        let outcome: WipeOutcomeFfi
        do {
            outcome = try await exitingClient.signOutAndWipe(accountRef: wipingRef)
        } catch {
            // Total FFI failure: nothing was wiped. Roll native push back.
            await restoreNativePushAfterFailedSignOut(
                using: exitingClient,
                accountRef: wipingRef,
                wasEnabled: nativePushWasEnabled
            )
            throw error
        }

        // Incomplete cleanup can still follow a committed removal (a secret
        // left behind). A runtime that suspension closed cannot answer, and
        // its wipe stopped before removal, so the profile stays for a retry.
        let presence: AccountPresence = outcome.localCleanup.completed
            ? .removed : await accountPresence(wipingRef, using: exitingClient, storedAccounts: nil)
        guard WipeReportProjection.removedLocalAccount(outcome, presence: presence) else {
            await restoreNativePushAfterFailedSignOut(
                using: exitingClient,
                accountRef: wipingRef,
                wasEnabled: nativePushWasEnabled
            )
            throw ProfileDataRemainsError()
        }

        nativePushRestoreIntents.clear(wipingRef)
        // MDK removed the account: the ref is invalid now. Do the same local
        // removal (and, for the active profile, routing) the normal sign-out
        // does — regardless of per-stage best-effort failures — then surface a
        // report only when something remains.
        let localCleanupFailures = await completeSignOut(
            removedRef: wipingRef,
            removedAccountIdHex: wipingAccountIdHex,
            destructive: true,
            routesAway: routesAway
        )

        let report = WipeReportProjection.report(
            from: outcome,
            additionalLocalFailures: localCleanupFailures
        )
        if !report.clean {
            pendingWipeReport = report
        }
    }

    @MainActor
    var allowsAutomaticAttachmentPolicySync: Bool {
        canUseLiveRuntime && isCurrentClientStarted && !blocksAccountWork
    }

    @MainActor
    func synchronizeAutomaticAttachmentPolicyIfAllowed(
        bridge: AttachmentPolicyBridge? = nil
    ) async throws {
        guard allowsAutomaticAttachmentPolicySync,
              let client = try? currentMarmotClient() else { return }
        try await (bridge ?? .shared).synchronize(client)
    }

    func eraseAppData() async throws {
        guard !isErasingAppData, !isSigningOut, phaseOwnsLiveRuntime,
              canUseRuntimeForLocalForegroundWork, let erasingClient = client else {
            throw ForegroundRuntimeMutationError.runtimeUnavailable
        }
        erasureState.begin()
        isErasingAppData = true
        isSigningOut = true
        // Detach the attachment bridge synchronously before the first `await` so
        // `NWPathMonitor` network changes cannot grant permissions mid-drain.
        let attachmentPolicyTail = AttachmentPolicyBridge.shared.detach(client: erasingClient)
        AvatarCacheErasure.begin()
        defer {
            AvatarCacheErasure.end()
            isErasingAppData = false
            finishAccountExit()
        }
        do {
            pendingAccountSetup?.suspend()
            await pendingAccountSetup?.drain()
            signUpRestorationTask?.cancel()
            _ = try? await signUpRestorationTask?.value
            await appReviewDemo.resetForErasure()
            await runtimeLifecycle.prepareForAppErasure()
            _ = try? await attachmentPolicyTail?.value
            await AttachmentPolicyBridge.shared.revokeAndDetach(client: erasingClient)
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
            try await signUpDraftStore.clear(id: signUpModel.draft.id)
            signUpModel = CreateIdentityViewModel()
            hasRestoredSignUp = false
            restoreSignUpPresentation = false
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
            notifications.removeAllNotifications()
            await notifications.drainNotificationCenterMutations()
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
            startupDiagnosticsEnabled = false
            blockScreenshots = false
            resetQuickReactions()
            appLock.reset()
            MediaAutoDownloadStore.shared.resetToDefaults()
            MediaQualityStore.setQuality(.standard)
            RemoteGIFLoadingStore.shared.setAutomaticallyLoads(false)
            LinkPreviewSettingsStore.shared.setShowsPreviews(false)
            LinkPreviewLoader.clearCaches()
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)?
                .removePersistentDomain(forName: AppContainerConfig.appGroupIdentifier)
            try DonationKeychainAccessStore.eraseAllAppData()
            signInAttempts.reset()
            nativePushRestoreIntents.reset()
            diagnosticsConsent.reset()
            resetInMemoryStateForErasure()
            erasureState.complete()
            appDataErasureGeneration += 1
            phase = .onboarding
            await finishErasureRuntimeTransition()
        } catch {
            await finishErasureRuntimeTransition()
            erasureState.failed()
            present(.error(L10n.string("Erasure didn’t finish. Some data may remain. Try again.")))
            throw error
        }
    }

    func resetInMemoryStateForErasure() {
        deviceLinks.resetForErasure()
        historyNotices.clear()
        recentDirectChatPeers = RecentDirectChatPeerStore()
        recentCreatedChatRows = RecentCreatedChatRowStore()
        pendingAccountSetupReadiness.removeAll()
        latestAccountAttention = nil
        accountExitIntent = nil
        checkedRetainedUndeliveredChanges = false
    }

    private func finishErasureRuntimeTransition() async {
        isErasingAppData = false
        finishAccountExit()
        await runtimeLifecycle.finishAppErasureRuntimeTransition()
    }

    @MainActor
    private func restoreNativePushAfterFailedSignOut(
        using client: MarmotClient,
        accountRef: String,
        wasEnabled: Bool
    ) async {
        guard wasEnabled else { return }
        // A runtime that suspension is closing refuses the write; the intent
        // then stays for the next live runtime's push sync.
        if (try? await client.marmot.setNativePushEnabled(accountRef: accountRef, enabled: true)) != nil {
            nativePushRestoreIntents.clear(accountRef)
        }
        finishAccountExit()
        scheduleNativePushRegistrationIfEnabled()
    }

    /// Turns native push back on for profiles an interrupted account exit
    /// left with it off. Runs before each foreground push sync, on a live
    /// runtime and never during an exit.
    func restorePendingNativePush() async {
        guard !nativePushRestoreIntents.accountRefs.isEmpty, !isSigningOut,
              let restoringClient = client else { return }
        let storedAccounts = try? await restoringClient.listAccounts()
        for accountRef in nativePushRestoreIntents.accountRefs.sorted() {
            guard !Task.isCancelled, !isSigningOut else { return }
            let presence = await accountPresence(accountRef, using: restoringClient, storedAccounts: storedAccounts)
            guard !Task.isCancelled, !isSigningOut else { return }
            switch NativePushRestoreIntents.action(for: presence) {
            case .restore:
                if (try? await restoringClient.marmot.setNativePushEnabled(accountRef: accountRef, enabled: true)) != nil {
                    nativePushRestoreIntents.clear(accountRef)
                }
            case .discard:
                nativePushRestoreIntents.clear(accountRef)
            case .wait:
                continue
            }
        }
    }

    /// Lists first, then confirms an unlisted account with a strict lookup.
    private func accountPresence(
        _ accountRef: String,
        using client: MarmotClient,
        storedAccounts: [AccountSummaryFfi]?
    ) async -> AccountPresence {
        let listed: [AccountSummaryFfi]?
        if let storedAccounts {
            listed = storedAccounts
        } else {
            listed = try? await client.listAccounts()
        }
        if listed?.contains(where: { $0.label == accountRef }) == true {
            return AccountPresence.resolve(accountRef: accountRef, storedAccounts: listed, lookupError: nil)
        }
        do {
            _ = try await client.accountSetupReadiness(accountRef: accountRef)
            return .unknown
        } catch {
            return AccountPresence.resolve(accountRef: accountRef, storedAccounts: listed, lookupError: error)
        }
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
        guard !blocksAccountWork else { return }
        await notificationCoordinator.syncNativePushRegistrationIfEnabled(host: self)
    }

    func scheduleNativePushRegistrationIfEnabled() {
        guard !blocksAccountWork else { return }
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
        let timing = productAnalytics.beginTiming()
        defer { productAnalytics.recordTiming(.composerMarkdown, since: timing) }
        return await client.parseMarkdown(text: text)
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

    func diagnosticLogExport(path: String? = nil) async throws -> DiagnosticLogSnapshot {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let files = try await lease.client.auditLogFiles()
        let file = try DiagnosticLogExport.fileForExport(in: files, path: path)
        return try await Task.detached(priority: .userInitiated) {
            try await DiagnosticLogExport.snapshotRetrying(file: file)
        }.value
    }

    /// Every audit log changed within `window`, zipped into one temporary
    /// file. The caller removes it with `DiagnosticLogExport.removeShareFile`.
    func diagnosticLogArchive(window: DiagnosticLogExport.Window, now: Date = Date()) async throws -> DiagnosticLogShareFile {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let files = DiagnosticLogExport.files(in: try await lease.client.auditLogFiles(), changedWithin: window, now: now)
        guard !files.isEmpty else { throw DiagnosticLogExport.ExportError.noLogs }
        let baseName = DiagnosticLogExport.archiveBaseName(window: window, now: now)
        return try await Task.detached(priority: .userInitiated) {
            try await DiagnosticLogExport.writeArchive(files: files, baseName: baseName) { file in
                try await DiagnosticLogExport.snapshotRetrying(file: file)
            }
        }.value
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
        guard !blocksAccountWork else { return }
        await notificationCoordinator.catchUpAfterForegroundActivation(host: self)
    }

    func scheduleConnectivityCatchUp(connectivityRestored: Bool = false) {
        guard !blocksAccountWork else { return }
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
        // Start the draft flush promptly before scheduling suspension; the
        // suspension task waits for this mutation lease under a bounded timeout
        // before closing SQLCipher so final composer keystrokes cannot race
        // teardown without risking 0xdead10cc.
        let draftLease = try? runtimeLifecycle.beginForegroundRuntimeMutation()
        let conversationDraftStore = conversationDraftStore
        let runtimeLifecycle = runtimeLifecycle
        let draftFlushTask: Task<Void, Never>? = draftLease.map { lease in
            Task { @MainActor in
                defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
                await conversationDraftStore.flush(using: lease.client)
            }
        }
        let runtimeSuspensionTask = runtimeLifecycle.startRuntimeSuspension()
        return Task { @MainActor in
            await draftFlushTask?.value
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

    /// Removes a profile another device unlinked from this one, so the user can
    /// sign in again and link this device anew. MDK's wipe skips leaving chats
    /// and deleting the KeyPackage slot, which the other devices already did.
    /// Throws `ProfileNotUnlinkedError`, wiping nothing, when MDK no longer
    /// lists that profile as unlinked (a notice for a copy since replaced).
    @MainActor
    func removeUnlinkedAccount(accountRef: String) async throws {
        guard !blocksAccountWork else {
            throw ForegroundRuntimeMutationError.runtimeUnavailable
        }
        let account = accounts.first { $0.label == accountRef || $0.accountIdHex == accountRef }
        if let account, account.label == activeAccountRef {
            try await wipeActiveAccount(account.label, requiringUnlinked: true)
            deviceLinks.retireUnlinkedNotice(account.accountIdHex)
            return
        }
        // Another profile (or none) is active: wipe this one the same way, but
        // leave whichever profile is open where it is.
        guard !isSigningOut else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        isSigningOut = true
        notifications.cancelForegroundBatches(accountRef: account?.label ?? accountRef)
        defer {
            finishAccountExit()
            scheduleNativePushRegistrationIfEnabled()
        }
        let unlinked = try await requireUnlinked(account?.label ?? accountRef, using: lease.client)
        // As for the active wipe: a sign-in's notification defaults must not
        // register push again after the wipe clears it.
        await awaitCancelledForegroundMutationFollowups()
        try await wipeAccount(unlinked.label, accountIdHex: unlinked.accountIdHex, using: lease.client, routesAway: false)
        deviceLinks.retireUnlinkedNotice(unlinked.accountIdHex)
    }

    /// Reads MDK's current account list, so a stale notice can't wipe a copy
    /// of the profile that was signed in again since.
    @MainActor
    private func requireUnlinked(_ accountRef: String, using client: MarmotClient) async throws -> AccountSummaryFfi {
        guard let account = try await client.listAccounts()
            .first(where: { $0.label == accountRef || $0.accountIdHex == accountRef }),
            account.unlinked else { throw ProfileNotUnlinkedError() }
        return account
    }


    /// Another of the account's devices removed this one. MDK has already
    /// signed the account out here, but it stays listed (`unlinked`), so leave
    /// it the way a sign-out does: to another profile's chooser, or Welcome.
    @MainActor
    func leaveUnlinkedAccount(accountIdHex: String) async {
        guard !blocksAccountWork else { return }
        do {
            try await refreshAccounts()
        } catch {
            // MDK reported the unlink, so leave even when the refresh failed:
            // mark the row the way MDK lists it, so the chooser doesn't offer it.
            if let index = accountStore.accounts.firstIndex(where: { $0.accountIdHex == accountIdHex }) {
                accountStore.accounts[index].signedOut = true
                accountStore.accounts[index].unlinked = true
            }
        }
        guard let active = activeAccount, active.accountIdHex == accountIdHex else { return }
        activeAccountRef = nil
        _ = stopNotificationSubscription()
        phase = accounts.contains(where: { !$0.signedOut && $0.accountIdHex != accountIdHex }) ? .ready : .onboarding
    }

    /// Internal (not `private`) so `RuntimeLifecycle.performBootstrap` can drive
    /// the account refresh once the runtime is online. The account refresh
    /// itself stays on AppState (it is account/profile maintenance, not
    /// lifecycle).
    @MainActor
    func refreshAccounts(refreshUnreadSummaries: Bool = true) async throws {
        let setupAtReadStart = pendingAccountSetup
        let attemptRevision = signInAttempts.revision
        let client = try runtimeClient()
        let localAccounts = try await accountRefreshReads.listAccounts(client)
        try await restoreSignUpIfNeeded(accounts: localAccounts, client: client)
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
                snapshot = try await accountRefreshReads.onboardingSnapshot(client, account.accountIdHex)
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
        readyAccounts.removeAll { isUnfinishedSignUpAccount($0.accountIdHex) }
        accountStore.accounts = readyAccounts
        if let activeAccountRef, !readyAccounts.contains(where: { $0.label == activeAccountRef }) {
            self.activeAccountRef = nil
        }
        accountSetupSnapshots = unfinished
        onboardingRecoveryAccounts = recoveryAccounts
        if !blocksAccountWork {
            deviceLinks.remindUnlinkedProfiles(readyAccounts)
        }
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

    @ObservationIgnored private var attentionTask: Task<Void, Never>?
    @ObservationIgnored private var attentionTaskID: UUID?
    @ObservationIgnored private var attentionDrainInProgress = false
    @ObservationIgnored private var latestAccountAttention: AccountAttentionSnapshotFfi?

    private func startAccountAttentionIfNeeded() {
        guard !attentionDrainInProgress, attentionTask == nil, canUseRuntimeForForegroundWork, let client else { return }
        let id = UUID()
        attentionTaskID = id
        attentionTask = Task { @MainActor [weak self] in
            defer {
                if self?.attentionTaskID == id {
                    self?.attentionTask = nil
                    self?.attentionTaskID = nil
                }
            }
            while !Task.isCancelled {
                do {
                    let subscription = try await client.subscribeAccountAttention()
                    guard let initial = await Task.detached(priority: .utility, operation: {
                        subscription.snapshot()
                    }).value else { throw CancellationError() }
                    var cursor = ProjectionSequenceCursor(
                        generation: initial.subscriptionGeneration, sequence: initial.sequence
                    )
                    guard !Task.isCancelled, self?.attentionTaskID == id else { return }
                    self?.applyAccountAttention(initial)
                    while let update = try await subscription.nextCancellable() {
                        guard !Task.isCancelled, self?.attentionTaskID == id else { return }
                        guard update.subscriptionGeneration == cursor.generation else { break }
                        guard cursor.accept(generation: update.subscriptionGeneration, sequence: update.sequence) else { continue }
                        self?.applyAccountAttention(update)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Keep the last known totals during a temporary read outage.
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func applyAccountAttention(_ snapshot: AccountAttentionSnapshotFfi) {
        latestAccountAttention = snapshot
        accountUnreadStore.applyAttention(snapshot, accounts: accounts)
        scheduleApplicationBadgeSynchronization()
    }

    @ObservationIgnored private var unreadSummaryRefreshGeneration = 0
    /// Tracked so suspension can drain an in-flight badge refresh before the
    /// runtime shuts down; an escaping task could otherwise hold the FFI
    /// handle mid-`accountUnreadSummary()` while terminal storage close runs.
    @ObservationIgnored private var unreadSummaryRefreshTask: Task<Void, Never>?
#if DEBUG
    // Documented exception (AGENTS.md): holds a badge refresh before its client
    // guard and attention early return, and stays (#1241, item 21).
    @ObservationIgnored var beforeUnreadSummaryRefreshForTesting: (() async -> Void)?
#endif

    /// Fire-and-forget wrapper for foreground resume — background reads and
    /// notification actions can move the read cursor while the cached summary
    /// goes stale.
    @MainActor
    func scheduleAccountUnreadSummaryRefresh() {
        guard !blocksAccountWork else { return }
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
        attentionDrainInProgress = true
        defer { attentionDrainInProgress = false }
        let attention = attentionTask
        attentionTaskID = nil
        attentionTask = nil
        attention?.cancel()
        await attention?.value
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
        guard !blocksAccountWork else { return }
        let targetAccounts: [AccountSummaryFfi]
        if accounts.isEmpty {
            // Cold UI-less notification actions run on an ephemeral frozen
            // runtime without running durable bootstrap, so `accounts` is still
            // empty. Read the account list from the leased client so badge
            // updates stay accurate without wiping the badge on failure.
            guard let leasedClient, phase == .bootstrapping else {
                accountUnreadStore.refreshed(from: [], accounts: [])
                await synchronizeApplicationBadge()
                return
            }
            guard let loadedAccounts = try? await leasedClient.listAccounts() else { return }
            guard !loadedAccounts.isEmpty else {
                accountUnreadStore.refreshed(from: [], accounts: [])
                await synchronizeApplicationBadge()
                return
            }
            targetAccounts = loadedAccounts
        } else {
            targetAccounts = accounts
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
        if leasedClient == nil {
            startAccountAttentionIfNeeded()
            if attentionTask != nil {
                if let latestAccountAttention { applyAccountAttention(latestAccountAttention) }
                return
            }
        }
        unreadSummaryRefreshGeneration += 1
        let generation = unreadSummaryRefreshGeneration
        let incrementalBaseline = accountUnreadStore.incrementalRevisionSnapshot()
        do {
            let summaries = try await summaryClient.accountUnreadSummaries()
            guard generation == unreadSummaryRefreshGeneration else { return }
            accountUnreadStore.refreshed(
                from: summaries,
                accounts: targetAccounts,
                preservingUpdatesAfter: incrementalBaseline
            )
            await synchronizeApplicationBadge()
        } catch {
            guard generation == unreadSummaryRefreshGeneration else { return }
            guard !accounts.isEmpty else { return }
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

    func accountUnreadIsUnavailable(forAccountIdHex accountIdHex: String) -> Bool {
        accountUnreadStore.unavailableAccountIds.contains(accountIdHex)
    }

    @MainActor
    private func applicationBadgeCount() -> Int? {
        accountUnreadStore.applicationBadgeCount()
    }

    @MainActor
    private func scheduleApplicationBadgeSynchronization() {
        guard let count = applicationBadgeCount() else { return }
        notifications.scheduleApplicationBadgeCount(count)
    }

    @MainActor
    private func synchronizeApplicationBadge() async {
        guard let count = applicationBadgeCount() else { return }
        await notifications.setApplicationBadgeCount(count)
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
    /// An `initialProfile` becomes the identity's first public kind-0, so
    /// relays and contacts never see MDK's generated name first.
    @MainActor
    func createIdentityForProfileSetup(
        initialProfile: UserProfileMetadataFfi? = nil
    ) async throws -> IdentityCreationResultFfi {
        let ticket = productAnalytics.ticket()
        productOnboardingTicket = ticket
        productAnalytics.record(.onboarding(.identitySelection, .create, .success), ticket: ticket)
        var created = false
        defer { if !created { productAnalytics.record(.onboarding(.localReady, .create, .failure), ticket: ticket) } }
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let relays = lease.client.relayUrls
        let existingAccountLabels = Set(accounts.map(\.label))
        let defaultRelays = AppContainerConfig.accountRelays(runtimeRelays: relays)
        let creation = if let initialProfile {
            try await lease.client.marmot.createIdentityWithInitialProfile(
                profile: initialProfile,
                defaultRelays: defaultRelays,
                bootstrapRelays: relays,
                inboxRelays: relays
            )
        } else {
            try await lease.client.marmot.createIdentityWithProfile(
                defaultRelays: defaultRelays,
                bootstrapRelays: relays,
                inboxRelays: relays
            )
        }
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
    func waitForIdentityProfileSetup(accountRef: String, retry: Bool) async throws {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        let client = lease.client
        let readiness = try await client.accountSetupReadiness(accountRef: accountRef)
        if retry, readiness == .localReady || readiness == .publishing {
            // MDK start resumes journaled setup after its bounded retries stop.
            // Calling creation again could create another account if setup just finished.
            try Task.checkCancellation()
            try await client.marmot.start()
        }
        try await IdentitySetupReadinessWaiter.wait {
            try await client.accountSetupReadiness(accountRef: accountRef)
        }
        pendingAccountSetupReadiness[accountRef] = .networkReady
    }

    @MainActor
    func removeUnfinishedSignUpAccount(_ account: AccountSummaryFfi) async throws {
        guard !isSigningOut, account.localSigning,
              activeAccountRef != account.label,
              isUnfinishedSignUpAccount(account.accountIdHex) else {
            throw SignUpDraftStore.Failure.accountUnavailable
        }
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        isSigningOut = true
        defer {
            finishAccountExit()
            scheduleNativePushRegistrationIfEnabled()
        }
        await notificationCoordinator.cancelNativePushRegistrationTask()
        _ = try? await lease.client.marmot.clearPushRegistration(accountRef: account.label)
        try await lease.client.marmot.removeAccount(accountRef: account.label)
        pendingAccountSetupReadiness.removeValue(forKey: account.label)
    }

    func recoverOnboardingSetup(accountID: String) async throws {
        guard !isSigningOut else { throw MarmotKitError.OnboardingActionUnavailable }
        let lease = try await runtimeLifecycle.beginUserInitiatedForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        guard try await lease.client.onboardingRecoveryRequired(accountRef: accountID) else {
            throw MarmotKitError.OnboardingActionUnavailable
        }
        if let model = pendingAccountSetup, model.accountID == accountID {
            model.suspend()
            await model.drain()
        }
        guard !isSigningOut else { throw MarmotKitError.OnboardingActionUnavailable }
        _ = try await lease.client.recoverOnboarding(accountRef: accountID)
        signInAttempts.finish(accountID)
        if pendingAccountSetup?.accountID == accountID { pendingAccountSetup = nil }
        onboardingRecoveryAccounts.removeAll { $0.accountIdHex == accountID }
        // Recovery has committed; a later refresh failure must not report it as failed.
        try? await refreshAccounts(refreshUnreadSummaries: false)
    }

    /// Remove only an explicitly selected, inactive profile with a broken setup.
    @MainActor
    func removeOnboardingRecoveryAccount(_ account: AccountSummaryFfi) async throws {
        guard !isSigningOut, account.localSigning,
              activeAccountRef != account.label,
              onboardingRecoveryAccounts.contains(where: { $0.accountIdHex == account.accountIdHex }) else {
            throw MarmotKitError.OnboardingActionUnavailable
        }
        let lease = try await runtimeLifecycle.beginUserInitiatedForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        guard try await lease.client.onboardingRecoveryRequired(accountRef: account.accountIdHex) else {
            throw MarmotKitError.OnboardingActionUnavailable
        }
        guard !isSigningOut, activeAccountRef != account.label else {
            throw MarmotKitError.OnboardingActionUnavailable
        }
        isSigningOut = true
        defer {
            finishAccountExit()
            scheduleNativePushRegistrationIfEnabled()
        }
        if let model = pendingAccountSetup, model.accountID == account.accountIdHex {
            model.suspend()
            await model.drain()
        }
        await notificationCoordinator.cancelNativePushRegistrationTask()
        _ = try? await lease.client.marmot.clearPushRegistration(accountRef: account.label)
        try await lease.client.marmot.removeAccount(accountRef: account.label)
        signInAttempts.finish(account.accountIdHex)
        if pendingAccountSetup?.accountID == account.accountIdHex { pendingAccountSetup = nil }
        onboardingRecoveryAccounts.removeAll { $0.accountIdHex == account.accountIdHex }
        accountSetupSnapshots.removeAll { $0.accountIdHex == account.accountIdHex }
        pendingAccountSetupReadiness.removeValue(forKey: account.label)
        conversationDraftStore.removeDrafts(accountRef: account.label)
        await conversationDraftStore.flush()
        MessageHideStore.clearAll(accountRef: account.label)
        ChatMuteStore.clearAll(accountIdHex: account.accountIdHex)
        profileStore.clearContactNicknames(ownerAccountIdHex: account.accountIdHex)
        profileStore.clearForAccountRemoval(accountIdHex: account.accountIdHex)
        // Removal has committed; a later refresh failure must not report it as failed.
        try? await refreshAccounts(refreshUnreadSummaries: false)
    }

    @MainActor
    func completeIdentityProfileSetup(_ summary: AccountSummaryFfi) async {
        restoreSignUpPresentation = false
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

    /// Finishes a generated secondary identity without changing which profile
    /// the app is presenting. The App Review demo uses this after MDK reports
    /// that Johnny's initial KeyPackage publication is network-ready.
    @MainActor
    func completeSecondaryIdentityProfileSetup(_ summary: AccountSummaryFfi) async {
        await productAnalytics.record(
            .onboarding(.complete, .create, .success),
            ticket: productOnboardingTicket
        )?.value
        productOnboardingTicket = nil
        productOnboardingPath = nil
        pendingAccountSetupReadiness.removeValue(forKey: summary.label)
        cacheActivatedAccountSummaryIfNeeded(summary)
        updateProfileProjectionLocalAccountLabels()
        warmProfileProjection(forAccountIdHex: summary.accountIdHex)
        restartReadyForegroundMaintenanceIfStopped()
        do {
            try await refreshAccounts(refreshUnreadSummaries: false)
        } catch {
            scheduleAccountUnreadSummaryRefresh()
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
        let relays = lease.client.relayUrls
        let options = AccountSetupOptions.importOptions(runtimeRelays: relays)
        var snapshot: OnboardingSnapshotFfi
        do {
            let existing = try await lease.client.listAccounts()
            snapshot = try await lease.client.marmot.beginOnboarding(
                nsec: identity,
                options: options
            )
            if !snapshot.ready, existing.contains(where: { $0.accountIdHex == snapshot.accountIdHex }) {
                snapshot = try await AccountSetupRecovery.restartIfPossible(
                    snapshot: snapshot,
                    cancel: { try await lease.client.marmot.cancelOnboarding(accountRef: snapshot.accountIdHex) },
                    begin: {
                        try await lease.client.marmot.beginOnboarding(
                            nsec: identity,
                            options: options
                        )
                    }
                )
            }
        } catch MarmotKitError.OnboardingActionUnavailable {
            // Legacy active/pending accounts keep their existing recovery path.
            // MDK's login gate refuses an unfinished interactive checkpoint.
            let summary = try await lease.client.marmot.login(
                identity: identity,
                defaultRelays: AppContainerConfig.accountRelays(runtimeRelays: relays),
                bootstrapRelays: relays,
                inboxRelays: relays
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
        pendingAccountSetup?.acknowledgesSingleDevice = true
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
        let relays = lease.client.relayUrls
        let summary: AccountSummaryFfi
        do {
            summary = try await lease.client.marmot.loginRecoveringIncompleteSetup(
                nsec: identity,
                defaultRelays: AppContainerConfig.accountRelays(runtimeRelays: relays),
                bootstrapRelays: relays,
                acknowledgePossibleKeyPackageOrphan: true,
                inboxRelays: relays
            )
        } catch let error as MarmotKitError {
            switch error {
            case .AccountSetupRetryRequired, .AccountSetupKeyPackageRecoveryAvailable:
                // The account became safely resumable between the original
                // failure and consent. Resume it without asking for the nsec
                // again or resetting recoverable KeyPackage material.
                summary = try await lease.client.marmot.login(
                    identity: identity,
                    defaultRelays: AppContainerConfig.accountRelays(runtimeRelays: relays),
                    bootstrapRelays: relays,
                    inboxRelays: relays
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
        guard !blocksAccountWork else { return }
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

    /// Account exit must not race a new identity's notification defaults: an
    /// enable that lands while MDK deactivates the account re-registers push.
    private func awaitCancelledForegroundMutationFollowups() async {
        for task in cancelForegroundMutationFollowups() {
            await task.value
        }
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

    #if DEBUG
    // Documented exception (AGENTS.md): sign-out and wipe each call this in
    // their own copy of the push cleanup, and it stays (#1241, item 21).
    @ObservationIgnored var afterAccountExitClientCapturedForTesting: (() async -> Void)?

    // Documented exception (AGENTS.md): shows that suspension took over the
    // private badge-refresh task, and stays (#1241, item 21).
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

nonisolated enum GroupEventPresentationPolicy {
    /// Device-local membership changes (MDK 0.13): this copy was terminated or
    /// restored, or member-leave records were removed.
    static func refreshesMembershipPresentation(_ kind: GroupEventKindFfi) -> Bool {
        switch kind {
        case .localGroupCopyTerminated, .localGroupCopyRestored, .groupMemberLeavesRemoved:
            return true
        default:
            return false
        }
    }
}
