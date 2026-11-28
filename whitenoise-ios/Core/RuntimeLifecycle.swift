// swiftlint:disable no_test_hook_in_app_code
import Foundation
import Observation
import OSLog
import MarmotKit

/// Runtime handle for one notification action: either the live foreground
/// client (durable) or a lease-private frozen runtime built while the app's
/// durable runtime stays suspended or before cold bootstrap has started.
final class NotificationActionRuntimeLease {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    let actionID: UUID
    private var retainedClient: MarmotClient?
    let clientIdentity: ObjectIdentifier
    /// True when the lease owns a private ephemeral frozen runtime. It is
    /// never the app's client slot and must be shut down when the action
    /// completes; foreground never adopts it.
    let ownsEphemeralRuntime: Bool

    init(actionID: UUID, client: MarmotClient, ownsEphemeralRuntime: Bool) {
        self.actionID = actionID
        retainedClient = client
        clientIdentity = ObjectIdentifier(client)
        self.ownsEphemeralRuntime = ownsEphemeralRuntime
    }

    var client: MarmotClient {
        guard let retainedClient else {
            preconditionFailure("Notification action runtime lease already released")
        }
        return retainedClient
    }

    fileprivate func takeClientForRelease() -> MarmotClient? {
        defer { retainedClient = nil }
        return retainedClient
    }
}

/// Tracks a notification action while it is constructing or starting an
/// ephemeral frozen runtime (before `activeNotificationActionLease` exists) so
/// deadline expiration can cancel, close SQLCipher, and release the suspension
/// gate without stranding a partial runtime.
@MainActor
private final class PendingNotificationActionStart {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    let actionID: UUID
    var isExpired = false
    var constructionTask: Task<Result<MarmotClient, Error>, Never>?
    private var ephemeralClient: MarmotClient?

    init(actionID: UUID) {
        self.actionID = actionID
    }

    func setEphemeralClient(_ client: MarmotClient) {
        ephemeralClient = client
    }

    func takeEphemeralClientForRelease() -> MarmotClient? {
        defer { ephemeralClient = nil }
        return ephemeralClient
    }
}

enum NotificationActionError: Error {
    case runtimeUnavailable
    case markReadFailed
}

enum RuntimeOwnershipContentionError: LocalizedError {
    case retryWindowExhausted

    var errorDescription: String? {
        "White Noise is still finishing another secure background operation. Please try again."
    }
}

struct RuntimeConstructionRetryPolicy: Sendable {
    let delays: [Duration]

    nonisolated static let foreground = RuntimeConstructionRetryPolicy(
        delays: [
            .milliseconds(100),
            .milliseconds(200),
            .milliseconds(400),
            .milliseconds(800),
            .milliseconds(1_600),
            .milliseconds(3_200),
        ]
    )
}

enum ForegroundRuntimeMutationError: LocalizedError {
    case runtimeUnavailable

    var errorDescription: String? {
        "The secure runtime isn't ready yet. Try again in a moment."
    }
}

struct ForegroundRuntimeMutationLease {
    fileprivate let id: UUID
    let client: MarmotClient
}

private struct ForegroundMaintenanceCancellation {
    let foregroundActivation: Task<Void, Never>?
    let maintenance: ForegroundMaintenanceTasks?
}

/// Owns the Marmot runtime's lifecycle: the live `MarmotClient` handle, the
/// foreground/suspension gates, the runtime generation token, bootstrap, and the
/// background suspend / foreground resume orchestration (including the
/// suspension-waiter machinery and the lifecycle `Task`s).
///
/// Carved out of `AppState` (Phase 2). `AppState` keeps thin forwarding
/// properties/methods (`client`, `runtimeGeneration`,
/// `canUseRuntimeForForegroundWork`, `bootstrap()`, `setAppSceneActive(_:)`,
/// `startForegroundActivation()`, `startRuntimeSuspension()`, …) so every
/// external and internal call site is unchanged.
///
/// The runtime gates also consult `isAppSceneActive`, which stays on `AppState`
/// (it is read by many non-lifecycle gates — notification presentation, settings
/// reads, push scheduling, routing); this store reads/writes it through the
/// `appState` back-reference so every gate computes the same boolean. Likewise,
/// the account/notification/profile maintenance that bootstrap and resume drive
/// (account refresh, notification subscription, native-push registration,
/// profile warming/queue) is not lifecycle — this store hands back to `AppState`
/// for it via the back-reference.
@Observable
@MainActor
final class RuntimeLifecycle {
    typealias RuntimeClientFactory = @Sendable (
        _ rootPath: String,
        _ relayUrls: [String],
        _ cursorPersistence: CursorPersistenceFfi,
        _ telemetryConfig: TelemetryBuildConfig
    ) async throws -> MarmotClient
    typealias RuntimeStarter = @Sendable (_ client: MarmotClient) async throws -> Void
    typealias RuntimeCloser = @Sendable (_ client: MarmotClient) async throws -> Void
    typealias RetrySleeper = @Sendable (_ delay: Duration) async throws -> Void
    /// Sends one `host_*` stage timing to the runtime that measured it.
    typealias HostPerformanceRecorder = @MainActor (
        _ client: MarmotClient,
        _ operation: HostPerformanceOperationFfi,
        _ durationMs: UInt64,
        _ outcome: HostPerformanceOutcomeFfi
    ) -> Void

    /// Upper bound for waiting on active foreground mutation leases (such as the
    /// background draft flush) before terminal SQLCipher closure. Kept well
    /// inside UIKit's ~30 s background assertion so `0xdead10cc` is never risked.
    nonisolated static let defaultForegroundMutationDrainTimeout: Duration = .seconds(2)

    /// The live FFI runtime. Released (`nil`) while the app is suspended in the
    /// background so its SQLite storage in the shared App Group container is
    /// closed and its file lock freed — otherwise iOS terminates the app at
    /// suspension with `0xdead10cc` ("held a file lock in a shared container").
    /// Rebuilt on foreground in `resumeAfterForegroundActivation`.
    @ObservationIgnored private(set) var client: MarmotClient?
    @ObservationIgnored private let runtimeRootPath: String?
    @ObservationIgnored private let runtimeRelayUrls: [String]
    @ObservationIgnored private let suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig
    @ObservationIgnored private let runtimeClientFactory: RuntimeClientFactory
    @ObservationIgnored let attachmentPolicyBridge: AttachmentPolicyBridge
    @ObservationIgnored private let runtimeStarter: RuntimeStarter
    @ObservationIgnored private let runtimeCloser: RuntimeCloser
    @ObservationIgnored private let retrySleeper: RetrySleeper
    @ObservationIgnored private let constructionRetryPolicy: RuntimeConstructionRetryPolicy
    @ObservationIgnored private let mutationDrainSleeper: RetrySleeper
    @ObservationIgnored private let hostPerformanceRecorder: HostPerformanceRecorder

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTaskID = UUID()
    @ObservationIgnored private var foregroundActivationTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundActivationTaskID = UUID()
    @ObservationIgnored private var runtimeSuspensionTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeSuspensionTaskID = UUID()
    @ObservationIgnored private var runtimeSuspensionClosePendingID: UUID?
    @ObservationIgnored private var activeNotificationActionLease: NotificationActionRuntimeLease?
    @ObservationIgnored private var pendingNotificationActionStart: PendingNotificationActionStart?
    @ObservationIgnored private var notificationActionReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var notificationActionReleaseTaskID = UUID()
    @ObservationIgnored private var notificationActionReleaseActionID: UUID?
    @ObservationIgnored private var notificationActionReleaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var notificationActionBackgroundEntryHandler: (actionID: UUID, handler: @MainActor () -> Void)?
    @ObservationIgnored private var backgroundStorageCloseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var runtimeSuspensionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var suspensionStorageCloseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var bootstrapRegistrationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var foregroundMutationLeaseIDs: Set<UUID> = []
    @ObservationIgnored private var foregroundMutationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// True while a real `.background` transition (`startRuntimeSuspension`) has
    /// an unsatisfied suspension request. Cleared by `startForegroundActivation()`
    /// and untouched by transient `.inactive` (`setAppSceneActive(false)`), so
    /// Face ID / App Lock overlays never revive an abandoned suspension. Tracked
    /// by `@Observable` so `canUseLiveRuntime` closes immediately on suspension.
    private var backgroundSuspensionRequested = false
    /// Detached cleanup tasks for already-cancelled maintenance from aborted
    /// suspensions or superseded activations. Terminal background suspension
    /// awaits these after closing SQLCipher.
    @ObservationIgnored private var pendingMaintenanceDrains: [UUID: Task<Void, Never>] = [:]
    /// Set when the real background-suspension entry point runs while bootstrap
    /// still has the phase at `.bootstrapping`. An `.inactive` scene transition
    /// only flips `isAppSceneActive`; it must not tear the runtime down until the
    /// app actually reaches `.background`.
    @ObservationIgnored private var bootstrapNeedsBackgroundSuspensionRecheck = false
#if DEBUG
    enum BackgroundSuspensionWait {
        /// Bootstrap is still running and owns the phase change.
        case bootstrap
        /// A notification action or other runtime work holds the suspension gate.
        case runtimeWork
    }

    // Documented exception (AGENTS.md): these three hooks sit inside the
    // launch, suspend and resume sequence and stay (#1241, item 19).
    @ObservationIgnored var afterBootstrapRuntimeStartForTesting: (() async -> Void)?
    @ObservationIgnored var afterForegroundRuntimeCreatedForTesting: (() async -> Void)?
    /// Called with `true` just before background suspension waits on a running
    /// bootstrap or on runtime work, and with `false` once it stops waiting, so
    /// a test can tell that the wait ended only after that work released it.
    @ObservationIgnored var backgroundSuspensionWaitForTesting: ((BackgroundSuspensionWait, _ isWaiting: Bool) -> Void)?
#endif
    /// Observed (like the original AppState stored flag) so the foreground/local
    /// runtime gates that fold it in stay reactive.
    private var isRuntimeSuspending = false
    private(set) var runtimeSuspendedForBackground = false
    /// True while the runtime is being (re)started after a background
    /// suspension and its account workers are hydrating local state. Marmot
    /// signals command-readiness before its initial relay sync completes, so
    /// this clears as soon as the restored client is published. Network catch-up
    /// has separate task ownership and must not hold the whole UI in a
    /// "Connecting…" state. MainActor-owned.
    private(set) var isRuntimeWarmingUp = false
    /// Observed identity of the client instance whose `startRuntime()` succeeded.
    /// Comparing against `client` ties started-ness to the specific instance.
    private var startedClientID: ObjectIdentifier?
    var isCurrentClientStarted: Bool {
        guard let client, let startedClientID else { return false }
        return ObjectIdentifier(client) == startedClientID
    }
    private(set) var runtimeGeneration = 0
    @ObservationIgnored private var isBackgroundStorageCloseInProgress = false

    @ObservationIgnored private weak var appState: AppState?
    private static let foregroundResumeLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "foreground-resume"
    )
    private static let coldBootstrapLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "cold-bootstrap"
    )
    private static let runtimeOwnershipLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "runtime-ownership"
    )

    init(
        client: MarmotClient?,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig,
        attachmentPolicyBridge: AttachmentPolicyBridge? = nil,
        runtimeClientFactory: @escaping RuntimeClientFactory = RuntimeLifecycle.defaultRuntimeClientFactory,
        runtimeStarter: @escaping RuntimeStarter = RuntimeLifecycle.defaultRuntimeStarter,
        runtimeCloser: @escaping RuntimeCloser = RuntimeLifecycle.defaultRuntimeCloser,
        retrySleeper: @escaping RetrySleeper = RuntimeLifecycle.defaultRetrySleeper,
        constructionRetryPolicy: RuntimeConstructionRetryPolicy = .foreground,
        mutationDrainSleeper: @escaping RetrySleeper = RuntimeLifecycle.defaultRetrySleeper,
        hostPerformanceRecorder: @escaping HostPerformanceRecorder = RuntimeLifecycle.recordHostPerformanceOnClient
    ) {
        self.client = client
        let attachmentPolicyBridge = attachmentPolicyBridge ?? client?.attachmentPolicyBridge ?? .shared
        self.attachmentPolicyBridge = attachmentPolicyBridge
        client?.bindAttachmentPolicyBridge(attachmentPolicyBridge)
        self.runtimeRootPath = client?.rootPath
        self.runtimeRelayUrls = client?.relayUrls ?? MarmotClient.seedRelays
        self.suspendedRuntimeTelemetryBuildConfig = suspendedRuntimeTelemetryBuildConfig
        self.runtimeClientFactory = runtimeClientFactory
        self.runtimeStarter = runtimeStarter
        self.runtimeCloser = runtimeCloser
        self.retrySleeper = retrySleeper
        self.constructionRetryPolicy = constructionRetryPolicy
        self.mutationDrainSleeper = mutationDrainSleeper
        self.hostPerformanceRecorder = hostPerformanceRecorder
    }

    nonisolated static let defaultRetrySleeper: RetrySleeper = { delay in
        try await Task.sleep(for: delay)
    }

    nonisolated static func defaultRuntimeStarter(_ client: MarmotClient) async throws {
        try await client.startRuntime()
    }

    nonisolated static func defaultRuntimeCloser(_ client: MarmotClient) async throws {
        try await client.marmot.shutdownAndClose()
    }

    static func recordHostPerformanceOnClient(
        _ client: MarmotClient,
        _ operation: HostPerformanceOperationFfi,
        _ durationMs: UInt64,
        _ outcome: HostPerformanceOutcomeFfi
    ) {
        client.recordHostPerformance(operation: operation, durationMs: durationMs, outcome: outcome)
    }

    nonisolated static func defaultRuntimeClientFactory(
        rootPath: String,
        relayUrls: [String],
        cursorPersistence: CursorPersistenceFfi,
        telemetryConfig: TelemetryBuildConfig
    ) async throws -> MarmotClient {
        try await Task.detached(priority: .userInitiated) {
            try MarmotClient(
                rootPath: rootPath,
                relayUrls: relayUrls,
                cursorPersistence: cursorPersistence,
                telemetryConfig: telemetryConfig
            )
        }.value
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    deinit {
        bootstrapTask?.cancel()
        foregroundActivationTask?.cancel()
        runtimeSuspensionTask?.cancel()
    }

    // MARK: - Runtime gates

    var telemetryBuildConfig: TelemetryBuildConfig {
        client?.telemetryConfig ?? suspendedRuntimeTelemetryBuildConfig
    }

    private var isAppSceneActive: Bool { appState?.isAppSceneActive ?? false }
    private var sceneHasReportedPhase: Bool { appState?.sceneHasReportedPhase ?? false }
    private var hasReportedActiveScene: Bool { appState?.hasReportedActiveScene ?? false }

    var canRefreshProfiles: Bool {
        isAppSceneActive
            && !runtimeSuspendedForBackground
            && !runtimeWorkIsSuspending
            && appState?.blocksAccountWork != true
            && client != nil
    }

    var canUseRuntimeForLocalForegroundWork: Bool {
        guard appState?.isErasingAppData != true else { return false }
        return ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: runtimeWorkIsSuspending,
            hasRuntimeClient: client != nil
        )
    }
    var canUseRuntimeForForegroundWork: Bool {
        ForegroundRuntimeWorkGate.canUseForegroundWork(
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: runtimeWorkIsSuspending
        )
    }
    var canUseLiveRuntime: Bool {
        guard appState?.isErasingAppData != true else { return false }
        return ForegroundRuntimeWorkGate.canUseLiveRuntime(
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: runtimeWorkIsSuspending || backgroundSuspensionRequested,
            hasRuntimeClient: client != nil
        )
    }
    var canUseLiveRuntimeWork: Bool {
        guard appState?.isErasingAppData != true else { return false }
        return ForegroundRuntimeWorkGate.canUseLiveRuntimeWork(
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: runtimeWorkIsSuspending || backgroundSuspensionRequested
        )
    }

    /// Exposes the suspension/suspended gate values to the notification and
    /// settings read gates that stay on `AppState`.
    var isRuntimeSuspendingNow: Bool { runtimeWorkIsSuspending }

    private var runtimeWorkIsSuspending: Bool {
        isRuntimeSuspending || isBackgroundStorageCloseInProgress
    }

    // MARK: - Runtime ownership

    func runtimeClient() throws -> MarmotClient {
        guard let client else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
        return client
    }

    /// Build a fresh runtime from the captured on-disk root and relay set. Used
    /// to restore the runtime after a background suspension released it.
    private func makeRuntime(
        cursorPersistence: CursorPersistenceFfi = .advance,
        retryOnTransientReadiness: Bool,
        stillOwnsWork: () -> Bool
    ) async throws -> MarmotClient {
        let rootPath = try runtimeRootPath ?? AppContainerConfig.productionMarmotRoot().path
        let relayUrls = runtimeRelayUrls
        let telemetryConfig = TelemetryBuildConfig.current()
        let startedAt = ContinuousClock.now
        var attempt = 1

        while true {
            try Task.checkCancellation()
            guard stillOwnsWork() else { throw CancellationError() }
            do {
                let restored = try await runtimeClientFactory(
                    rootPath,
                    relayUrls,
                    cursorPersistence,
                    telemetryConfig
                )
                restored.bindAttachmentPolicyBridge(attachmentPolicyBridge)
                return restored
            } catch let error as MarmotKitError where error.isTransientStartupReadinessFailure {
                guard retryOnTransientReadiness,
                      stillOwnsWork(),
                      attempt <= constructionRetryPolicy.delays.count
                else {
                    if retryOnTransientReadiness, stillOwnsWork() {
                        Self.runtimeOwnershipLog.error(
                            """
                            readiness_retry_exhausted operation=foreground \
                            attempts=\(attempt, privacy: .public) \
                            elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt), format: .fixed(precision: 0), privacy: .public)
                            """
                        )
                        if error.isRuntimeOwnershipContention {
                            throw RuntimeOwnershipContentionError.retryWindowExhausted
                        }
                        throw error
                    }
                    throw error
                }

                Self.runtimeOwnershipLog.info(
                    """
                    readiness_retry operation=foreground \
                    attempt=\(attempt, privacy: .public) \
                    elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt), format: .fixed(precision: 0), privacy: .public)
                    """
                )
                let delay = constructionRetryPolicy.delays[attempt - 1]
                attempt += 1
                try await retrySleeper(delay)
            }
        }
    }

    private func startCurrentRuntime(stillOwnsWork: () -> Bool) async throws {
        var retryIndex = 0
        while true {
            try Task.checkCancellation()
            guard stillOwnsWork() else { throw CancellationError() }
            if client == nil {
                let built = try await makeRuntime(
                    retryOnTransientReadiness: true,
                    stillOwnsWork: stillOwnsWork
                )
                guard stillOwnsWork(), !Task.isCancelled else {
                    _ = try? await built.marmot.shutdownAndClose()
                    throw CancellationError()
                }
                client = built
            }
            guard stillOwnsWork(), !Task.isCancelled else {
                await shutdownAndReleaseCurrentClient()
                throw CancellationError()
            }
            guard let startingClient = client else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
            startedClientID = nil
            do {
                try await runtimeStarter(startingClient)
                if client === startingClient {
                    startedClientID = ObjectIdentifier(startingClient)
                }
                return
            } catch let error as MarmotKitError where error.isTransientStartupReadinessFailure {
                guard stillOwnsWork(), retryIndex < constructionRetryPolicy.delays.count else {
                    throw error
                }
                await shutdownAndReleaseCurrentClient()
                let delay = constructionRetryPolicy.delays[retryIndex]
                retryIndex += 1
                try await retrySleeper(delay)
            }
        }
    }

    // MARK: - Bootstrap

    /// Brings the runtime online and refreshes the account list. Called once
    /// per app launch.
    @MainActor
    func bootstrap() async {
        await waitForRuntimeWorkAndActionReleaseToFinish()
        guard !Task.isCancelled else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let id = UUID()
        bootstrapTaskID = id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap(id: id)
            self.clearCompletedBootstrapTask(id: id)
        }
        bootstrapTask = task
        resumeBootstrapRegistrationWaiters()
        await task.value
    }

    @MainActor
    private func performBootstrap(id: UUID) async {
        guard let appState else { return }
        if runtimeSuspendedForBackground, !appState.isAppSceneActive {
            await shutdownAndReleaseCurrentClient()
            return
        }
        let bootstrapStartedAt = ContinuousClock.now
        let beganWhileInactive = appState.sceneHasReportedPhase
            && !appState.isAppSceneActive
            && !bootstrapNeedsBackgroundSuspensionRecheck
            && !backgroundSuspensionRequested
            && appState.phase == .bootstrapping
            && !runtimeSuspendedForBackground
        func bootstrapStillOwnsWork() -> Bool {
            self.bootstrapTaskID == id
                && !Task.isCancelled
                && (!self.sceneHasReportedPhase
                    || self.isAppSceneActive
                    || beganWhileInactive
                    || (self.appState?.phase == .bootstrapping && self.bootstrapNeedsBackgroundSuspensionRecheck))
        }
        var runtimeStartMilliseconds = 0.0
        var accountLoadMilliseconds = 0.0
        // The shared host stage in flight, so failure and cancellation close it.
        var openStage: (operation: HostPerformanceOperationFfi, startedAt: ContinuousClock.Instant)?
        do {
            let runtimeStartStartedAt = ContinuousClock.now
            openStage = (.runtimeInit, runtimeStartStartedAt)
            try await startCurrentRuntime(stillOwnsWork: bootstrapStillOwnsWork)
            runtimeStartMilliseconds = Self.elapsedMilliseconds(since: runtimeStartStartedAt)
            if let client {
                recordHostPerformance(using: client, operation: .runtimeInit, since: runtimeStartStartedAt, outcome: .success)
                appState.flushHostWindowInit(to: client)
            }
            openStage = nil
#if DEBUG
            if let afterBootstrapRuntimeStartForTesting {
                await afterBootstrapRuntimeStartForTesting()
            }
#endif
            guard bootstrapStillOwnsWork() else { throw CancellationError() }
            noteRuntimeForegroundReadyAfterSuspension()
            await appState.refreshProductAnalytics()
            guard bootstrapStillOwnsWork() else { throw CancellationError() }
            let accountLoadStartedAt = ContinuousClock.now
            openStage = (.accountLoad, accountLoadStartedAt)
            // Routing needs the durable account list, but unread badges do not
            // gate local conversation display. Refresh them after `.ready`.
            try await refreshAccountsForBootstrap(appState, stillOwnsWork: bootstrapStillOwnsWork)
            guard bootstrapStillOwnsWork() else { throw CancellationError() }
            accountLoadMilliseconds = Self.elapsedMilliseconds(since: accountLoadStartedAt)
            if let client {
                recordHostPerformance(using: client, operation: .accountLoad, since: accountLoadStartedAt, outcome: .success)
            }
            openStage = nil
            if appState.accounts.isEmpty {
                appState.activeAccountRef = nil
                appState.setPhase(.onboarding)
                if appState.sceneHasReportedPhase, appState.isAppSceneActive, let client {
                    recordHostPerformance(
                        using: client,
                        operation: .splashReady,
                        since: bootstrapStartedAt,
                        outcome: .success
                    )
                }
                Self.coldBootstrapLog.info(
                    """
                    local_ready phase=onboarding \
                    runtime_start_ms=\(runtimeStartMilliseconds, format: .fixed(precision: 0), privacy: .public) \
                    account_load_ms=\(accountLoadMilliseconds, format: .fixed(precision: 0), privacy: .public) \
                    total_ms=\(Self.elapsedMilliseconds(since: bootstrapStartedAt), format: .fixed(precision: 0), privacy: .public)
                    """
                )
                // `.onboarding` now owns a live runtime; re-arm suspension if a
                // background request landed while bootstrap was awaiting above.
                reconcileBackgroundSuspensionAfterBootstrap()
            } else {
                let needsErasureRecovery = appState.erasureState.blocksNormalAccountActivation
                if needsErasureRecovery {
                    appState.activeAccountRef = nil
                } else if !appState.accounts.contains(where: { $0.label == appState.activeAccountRef && !$0.signedOut }) {
                    appState.activeAccountRef = appState.accountStore.prefersProfileSelection || appState.signUpModel.isRestorationBlocked
                        ? nil : appState.accounts.first(where: { !$0.signedOut })?.label
                }
                appState.setPhase(appState.accounts.contains(where: { !$0.signedOut }) ? .ready : .onboarding)
                if appState.sceneHasReportedPhase, appState.isAppSceneActive, let client {
                    recordHostPerformance(
                        using: client,
                        operation: .splashReady,
                        since: bootstrapStartedAt,
                        outcome: .success
                    )
                }
                Self.coldBootstrapLog.info(
                    """
                    local_ready phase=ready \
                    runtime_start_ms=\(runtimeStartMilliseconds, format: .fixed(precision: 0), privacy: .public) \
                    account_load_ms=\(accountLoadMilliseconds, format: .fixed(precision: 0), privacy: .public) \
                    total_ms=\(Self.elapsedMilliseconds(since: bootstrapStartedAt), format: .fixed(precision: 0), privacy: .public)
                    """
                )
                // If the app was backgrounded during bootstrap, the suspension
                // task that landed at `.bootstrapping` must be chained through
                // bootstrap (or re-armed if it already bailed), so the started
                // runtime is not left alive across suspension holding the shared
                // App Group SQLite lock (0xdead10cc). Skip the `.ready`-only
                // foreground maintenance below in that backgrounded case.
                if reconcileBackgroundSuspensionAfterBootstrap() { return }
                // Keep surviving accounts out of normal maintenance until
                // unfinished erasure recovery completes.
                if needsErasureRecovery { return }
                // Warm the active account's profile (name + avatar) right away
                // so it's visible without waiting for a screen to request it.
                if let activeId = appState.activeAccount?.accountIdHex {
                    appState.warmProfileProjection(forAccountIdHex: activeId, refreshAfterLoad: true)
                }
                appState.scheduleAccountUnreadSummaryRefresh()
                appState.startReadyForegroundMaintenance()
            }
        } catch is CancellationError {
            if let openStage, let client {
                recordHostPerformance(using: client, operation: openStage.operation, since: openStage.startedAt, outcome: .cancelled)
            }
            // Backgrounding or losing bootstrap ownership is expected
            // lifecycle control flow. Leave the phase bootstrapping so the
            // next active transition can build a fresh runtime, and mark
            // live-runtime phases suspended so foreground return rebuilds.
            await releaseRuntimeAfterStartupFailure()
            if !isAppSceneActive, phaseOwnsLiveRuntime {
                runtimeSuspendedForBackground = true
            }
        } catch {
            if let openStage, let client {
                recordHostPerformance(using: client, operation: openStage.operation, since: openStage.startedAt, outcome: .failure)
            }
            if !(error is CancellationError),
               appState.sceneHasReportedPhase,
               appState.isAppSceneActive,
               let client {
                recordHostPerformance(
                    using: client,
                    operation: .splashReady,
                    since: bootstrapStartedAt,
                    outcome: .failure
                )
            }
            await releaseRuntimeAfterStartupFailure()
            appState.setPhase(.failed(UserFacingError.message(for: error)))
        }
    }

    /// Symmetry guard for the bootstrap↔suspension race. `performBootstrap`
    /// starts the runtime and only later promotes `phase` out of
    /// `.bootstrapping`; a real background transition that lands while bootstrap
    /// is awaiting reaches `prepareForBackgroundSuspension`. The suspension task
    /// waits for bootstrap to be registered and completed before re-evaluating
    /// the live-runtime guards, so the UIKit background task remains attached to
    /// one suspension task until the runtime is actually released.
    ///
    /// Call this *after* `setPhase(.onboarding/.ready)` so the pending/re-armed
    /// suspension passes `phaseOwnsLiveRuntime` and actually tears the runtime
    /// down. Returns `true` when a background suspension is pending so the `.ready`
    /// caller can skip starting foreground-only maintenance. A plain `.inactive`
    /// transition does not set `bootstrapNeedsBackgroundSuspensionRecheck`, so it
    /// continues to avoid starting suspension before the app reaches
    /// `.background`.
    @MainActor
    @discardableResult
    private func reconcileBackgroundSuspensionAfterBootstrap() -> Bool {
        let shouldRearm = (bootstrapNeedsBackgroundSuspensionRecheck || runtimeSuspensionTask != nil)
            && backgroundSuspensionRequested
        bootstrapNeedsBackgroundSuspensionRecheck = false
        guard shouldRearm else { return false }
        startRuntimeSuspension()
        return true
    }

    private func waitForBootstrapRegistrationIfNeeded() async {
        guard bootstrapTask == nil,
              appState?.phase == .bootstrapping,
              bootstrapNeedsBackgroundSuspensionRecheck,
              backgroundSuspensionRequested
        else { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard bootstrapTask == nil,
                      appState?.phase == .bootstrapping,
                      bootstrapNeedsBackgroundSuspensionRecheck,
                      backgroundSuspensionRequested,
                      !Task.isCancelled
                else {
                    continuation.resume()
                    return
                }
                bootstrapRegistrationWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeBootstrapRegistrationWaiter(id: waiterID)
            }
        }
    }

    private func resumeBootstrapRegistrationWaiters() {
        let waiters = Array(bootstrapRegistrationWaiters.values)
        bootstrapRegistrationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeBootstrapRegistrationWaiter(id: UUID) {
        bootstrapRegistrationWaiters.removeValue(forKey: id)?.resume()
    }

    /// Tear down a partially-created runtime after a failed start so the next
    /// Retry rebuilds a fresh one. Shared by the bootstrap and foreground-resume
    /// failure paths: both set `client` to a new instance and then start it, so
    /// both must release that instance (shutdown + `client = nil`) on failure —
    /// otherwise Retry can re-invoke `startRuntime()` on a stale client whose
    /// prior `start()` already failed.
    private func releaseRuntimeAfterStartupFailure() async {
        let notificationTask = appState?.stopNotificationSubscription()
        await appState?.cancelNativePushRegistrationTask()
        await notificationTask?.value
        await shutdownAndReleaseCurrentClient()
    }

    func prepareForAppErasure() async {
        let cancellation = beginForegroundMaintenanceCancellation()
        await drainForegroundMaintenance(cancellation)
    }

    func closeForAppErasure() async throws {
        await waitForRuntimeWorkAndActionReleaseToFinish()
        if let clientToClose = client {
            isBackgroundStorageCloseInProgress = true
            // `Marmot.shutdownAndClose()` is terminal and leaves every database
            // closed even when it throws, so always clear the spent handle and
            // mark the runtime suspended before releasing the storage-close gate.
            defer {
                self.client = nil
                startedClientID = nil
                runtimeSuspendedForBackground = true
                finishBackgroundStorageClose()
            }
            let policyTail = self.attachmentPolicyBridge.detach(client: clientToClose)
            do {
                try await runtimeCloser(clientToClose)
                _ = try? await policyTail?.value
            } catch {
                _ = try? await policyTail?.value
                throw error
            }
        } else {
            runtimeSuspendedForBackground = true
        }
    }

    /// Completes the runtime transition after app-data erasure finishes or fails.
    /// Foreground rebuilds route through `startForegroundActivation()` so there
    /// is a single startup owner that waits for any in-flight storage close and
    /// deduplicates against concurrent scene activations.
    func finishAppErasureRuntimeTransition() async {
        if isAppSceneActive {
            await startForegroundActivation().value
        } else {
            await suspendAfterBackgroundErasure()
        }
    }

    private func suspendAfterBackgroundErasure() async {
        await waitForSuspensionStorageCloseToFinish()
        if isAppSceneActive {
            await startForegroundActivation().value
            return
        }
        if client != nil {
            _ = startRuntimeSuspension()
            await waitForSuspensionStorageCloseToFinish()
            if isAppSceneActive {
                await startForegroundActivation().value
            }
        } else {
            runtimeSuspendedForBackground = true
        }
    }

    @discardableResult
    private func shutdownAndReleaseCurrentClient(
        awaitPolicyTail: Bool = true
    ) async -> Task<Void, Error>? {
        if let appState {
            appState.conversationOpenPerformance?.finish(.cancelled, recorder: appState.productAnalytics)
            appState.conversationOpenPerformance?.accountContextReady(
                ticket: appState.productAnalytics.ticket(), recorder: appState.productAnalytics)
        }
        appState?.invalidateProductAnalytics()
        let clientToRelease = client
        client = nil
        startedClientID = nil
        guard let clientToRelease else { return nil }
        let policyTail = self.attachmentPolicyBridge.detach(client: clientToRelease)
        try? await runtimeCloser(clientToRelease)
        if awaitPolicyTail {
            _ = try? await policyTail?.value
            return nil
        }
        return policyTail
    }

    private func refreshAccountsForBootstrap(
        _ appState: AppState,
        stillOwnsWork: () -> Bool
    ) async throws {
        var retryIndex = 0
        while true {
            try Task.checkCancellation()
            guard stillOwnsWork() else { throw CancellationError() }
            do {
                try await appState.refreshAccounts(refreshUnreadSummaries: false)
                return
            } catch let error as MarmotKitError where error.isTransientStartupReadinessFailure {
                guard stillOwnsWork(), retryIndex < constructionRetryPolicy.delays.count else {
                    throw error
                }
                let delay = constructionRetryPolicy.delays[retryIndex]
                retryIndex += 1
                try await retrySleeper(delay)
            }
        }
    }

    private func clearCompletedBootstrapTask(id: UUID) {
        guard bootstrapTaskID == id else { return }
        bootstrapTask = nil
    }

    // MARK: - Suspend / resume

    func setAppSceneActive(_ active: Bool) {
        appState?.isAppSceneActive = active
        appState?.sceneHasReportedPhase = true
        if !active {
            appState?.cancelNativePushRegistrationTaskSync()
        }
    }

    @discardableResult
    func startForegroundActivation() -> Task<Void, Never> {
        appState?.isAppSceneActive = true
        appState?.sceneHasReportedPhase = true
        backgroundSuspensionRequested = false
        // Time passed and settings may have changed while in the background.
        appState?.markdownTimestampClock.invalidate()
        guard appState?.isErasingAppData != true else { return Task {} }
        resumeBootstrapRegistrationWaiters()
        resumeAllForegroundMutationWaiters()
        if appState?.phase == .bootstrapping {
            return Task { [weak self] in
                guard let self else { return }
                await self.waitForRuntimeWorkAndActionReleaseToFinish()
                guard !Task.isCancelled else { return }
                await bootstrapTask?.value
                guard !Task.isCancelled, appState?.phase == .bootstrapping else { return }
                await bootstrap()
            }
        }
        if let foregroundActivationTask {
            return foregroundActivationTask
        }
        let id = UUID()
        foregroundActivationTaskID = id
        let task = Task { [weak self] in
            guard let self else { return }
            while true {
                await resumeAfterForegroundActivation(activationID: id)
                // If a transient `.inactive` caused teardown of a newly built
                // handle and `.active` returned before teardown finished
                // (joining this same task), rebuild once teardown completes.
                // Real startup failures transition to `.failed`
                // (`phaseOwnsLiveRuntime == false`) and never loop here.
                guard foregroundActivationTaskID == id,
                      !Task.isCancelled,
                      isAppSceneActive,
                      !backgroundSuspensionRequested,
                      appState?.isErasingAppData != true,
                      phaseOwnsLiveRuntime,
                      runtimeSuspendedForBackground || client == nil
                else { break }
            }
            clearCompletedForegroundActivationTask(id: id)
        }
        foregroundActivationTask = task
        return task
    }

    @discardableResult
    func startRuntimeSuspension() -> Task<Void, Never> {
        startRuntimeSuspensionWithCloseID().task
    }

    private func startRuntimeSuspensionWithCloseID() -> (task: Task<Void, Never>, closeID: UUID?) {
        if let appState {
            appState.conversationOpenPerformance?.finish(.cancelled, recorder: appState.productAnalytics)
            appState.conversationOpenPerformance?.accountContextReady(
                ticket: appState.productAnalytics.ticket(), recorder: appState.productAnalytics)
        }
        appState?.invalidateProductAnalytics()
        appState?.isAppSceneActive = false
        appState?.sceneHasReportedPhase = true
        backgroundSuspensionRequested = true
        notifyNotificationActionBackgroundEntry()
        if appState?.phase == .bootstrapping || bootstrapTask != nil {
            bootstrapNeedsBackgroundSuspensionRecheck = true
        }
        let cancelledActivation = foregroundActivationTask
        foregroundActivationTask = nil
        foregroundActivationTaskID = UUID()
        cancelledActivation?.cancel()
        if let cancelledActivation {
            trackPendingMaintenanceDrain(cancelledActivation)
        }
        appState?.cancelNativePushRegistrationTaskSync()
        if let runtimeSuspensionTask {
            return (runtimeSuspensionTask, runtimeSuspensionClosePendingID)
        }

        let suspensionID = UUID()
        runtimeSuspensionTaskID = suspensionID
        runtimeSuspensionClosePendingID = suspensionID
        let task = Task { [weak self] in
            guard let self else { return }
            await prepareForBackgroundSuspension(suspensionID: suspensionID)
        }
        runtimeSuspensionTask = task
        return (task, suspensionID)
    }

    private func clearRuntimeSuspensionTaskIfCurrent(id: UUID) {
        guard runtimeSuspensionTaskID == id else { return }
        runtimeSuspensionTask = nil
        resumeSuspensionStorageCloseWaitersIfReady()
    }

    private func trackPendingMaintenanceDrain(_ task: Task<Void, Never>) {
        let id = UUID()
        pendingMaintenanceDrains[id] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.pendingMaintenanceDrains.removeValue(forKey: id)
        }
    }

    /// Defers waiting on already-captured, already-cancelled maintenance handles
    /// so an aborted suspension returns immediately without holding
    /// `runtimeSuspensionTask` or `isBackgroundStorageCloseInProgress` across a
    /// slow catch-up unwind. Never invokes live-state cancellation helpers that
    /// could cancel a newer foreground activation's tasks.
    private func abortSuspension(draining cancellation: ForegroundMaintenanceCancellation) {
        let drainTask = Task { @MainActor in
            await cancellation.foregroundActivation?.value
            await cancellation.maintenance?.notificationSubscription?.value
            await cancellation.maintenance?.connectivityCatchUp?.value
            await cancellation.maintenance?.profileRefresh?.value
            if let mutationFollowups = cancellation.maintenance?.mutationFollowups {
                for task in mutationFollowups {
                    await task.value
                }
            }
        }
        trackPendingMaintenanceDrain(drainTask)
        if isAppSceneActive {
            startForegroundActivation()
        }
    }

    private func drainPendingMaintenanceDrains() async {
        while !pendingMaintenanceDrains.isEmpty {
            let drains = pendingMaintenanceDrains
            pendingMaintenanceDrains.removeAll()
            for drain in drains.values {
                await drain.value
            }
        }
    }

    private func prepareForBackgroundSuspension(suspensionID: UUID) async {
        var holdsStorageCloseGate = false
        func releaseStorageCloseGateIfHeld() {
            guard holdsStorageCloseGate else { return }
            holdsStorageCloseGate = false
            finishBackgroundStorageClose()
        }
        func finishAfterStorageSettled(_ cancellation: ForegroundMaintenanceCancellation) async {
            markSuspensionStorageCloseFinished(suspensionID: suspensionID)
            await drainForegroundMaintenance(cancellation)
            releaseStorageCloseGateIfHeld()
            clearRuntimeSuspensionTaskIfCurrent(id: suspensionID)
            await appState?.waitForAccountExitToFinish()
            await drainPendingMaintenanceDrains()
        }
        defer {
            releaseStorageCloseGateIfHeld()
            markSuspensionStorageCloseFinished(suspensionID: suspensionID)
            clearRuntimeSuspensionTaskIfCurrent(id: suspensionID)
        }
        // Stop admitting foreground maintenance immediately, but do not put
        // storage closure behind cancellation-sensitive drains. A subscription,
        // relay catch-up, or local read can otherwise consume the entire UIKit
        // background assertion while SQLCipher still holds its App Group lock.
        let cancellation = beginForegroundMaintenanceCancellation()
        // `backgroundSuspensionRequested` tracks whether an actual `.background`
        // transition still requires suspension. Foreground activation clears it;
        // transient `.inactive` overlays (Face ID, Control Center) do not re-set
        // it. Aborting defers the already-cancelled handles to
        // `pendingMaintenanceDrains` and returns synchronously (no `await`
        // between the guard and `runtimeSuspensionTask = nil`), so a subsequent
        // `.background` immediately starts a fresh suspension task and closes
        // SQLCipher even while an earlier catch-up is still parked.
        guard backgroundSuspensionRequested else {
            abortSuspension(draining: cancellation)
            return
        }
        // A very fast launch-to-background transition can arrive before the
        // SwiftUI bootstrap task has even registered, and a retry or explicit
        // bootstrap can run while phase is not `.bootstrapping` and
        // `runtimeSuspendedForBackground` is still true. Wait for any live
        // bootstrap under this same UIKit background assertion before releasing.
        if appState?.phase == .bootstrapping || bootstrapTask != nil {
            if appState?.phase == .bootstrapping {
                await waitForBootstrapRegistrationIfNeeded()
            }
#if DEBUG
            let waitsForBootstrap = bootstrapTask != nil
            if waitsForBootstrap { backgroundSuspensionWaitForTesting?(.bootstrap, true) }
#endif
            await bootstrapTask?.value
#if DEBUG
            if waitsForBootstrap { backgroundSuspensionWaitForTesting?(.bootstrap, false) }
#endif
            guard backgroundSuspensionRequested else {
                abortSuspension(draining: cancellation)
                return
            }
        }
        guard phaseOwnsLiveRuntime,
              !runtimeSuspendedForBackground || client != nil
        else {
            backgroundSuspensionRequested = false
            await finishAfterStorageSettled(cancellation)
            return
        }

        // A notification action can hold an explicit lease on the live client.
        // Unlike cancelled maintenance, that work must retain the runtime until
        // the action releases it; closing underneath the lease would invalidate
        // an in-flight reply or mark-read FFI call. This gate is independent of
        // the maintenance drains moved below terminal storage closure.
#if DEBUG
        // Same condition as the wait loop, so a cancelled task never reports a wait.
        let waitsForRuntimeWork = runtimeWorkIsSuspending && !Task.isCancelled
        if waitsForRuntimeWork { backgroundSuspensionWaitForTesting?(.runtimeWork, true) }
#endif
        await waitForRuntimeSuspensionToFinish()
#if DEBUG
        if waitsForRuntimeWork { backgroundSuspensionWaitForTesting?(.runtimeWork, false) }
#endif
        guard backgroundSuspensionRequested else {
            abortSuspension(draining: cancellation)
            return
        }
        guard phaseOwnsLiveRuntime, !runtimeSuspendedForBackground || client != nil else {
            backgroundSuspensionRequested = false
            await finishAfterStorageSettled(cancellation)
            return
        }

        isBackgroundStorageCloseInProgress = true
        holdsStorageCloseGate = true
        // Wait briefly for in-flight foreground runtime mutations (including
        // the background draft flush lease) before closing SQLCipher. Fall
        // through to terminal closure on timeout so 0xdead10cc is never risked.
        await waitForForegroundRuntimeMutations(timeout: Self.defaultForegroundMutationDrainTimeout)
        guard backgroundSuspensionRequested else {
            releaseStorageCloseGateIfHeld()
            abortSuspension(draining: cancellation)
            return
        }
        guard phaseOwnsLiveRuntime, !runtimeSuspendedForBackground || client != nil else {
            backgroundSuspensionRequested = false
            await finishAfterStorageSettled(cancellation)
            return
        }

        backgroundSuspensionRequested = false
        let backgroundClient = client
        let backgroundObservation = Task {
            try? await backgroundClient?.marmot.setProductAnalyticsActivity(activity: .background)
        }
        // Terminal shutdown closes storage before draining delivery; never await
        // the activity setter's network flush or policy-tail unwind before
        // releasing the database lock and signaling storage closure to any
        // notification action waiting to end its UIKit background assertion.
        let policyTail = await shutdownAndReleaseCurrentClient(awaitPolicyTail: false)
        // `shutdownAndClose()` explicitly closes every SQLite connection and
        // releases the root lease. Dropping only the top-level handle cannot
        // prove that while subscriptions and projections retain internal Arcs;
        // suspending with either lock is an iOS `0xdead10cc` kill.
        backgroundSuspensionRequested = false
        runtimeSuspendedForBackground = true
        markSuspensionStorageCloseFinished(suspensionID: suspensionID)
        _ = try? await policyTail?.value
        await backgroundObservation.value
        // Drain cancelled foreground maintenance before releasing the close gate
        // and `runtimeSuspensionTask` slot, then await account exit and earlier
        // drains (prevents erasure deadlock and lets a later `.background` close
        // any rebuilt runtime while keeping UIKit's assertion alive).
        await finishAfterStorageSettled(cancellation)
    }

    private func resumeAfterForegroundActivation(activationID: UUID) async {
        let resumeStartedAt = ContinuousClock.now
        let suspensionWaitStartedAt = ContinuousClock.now
        await bootstrapTask?.value
        await waitForRuntimeWorkAndActionReleaseToFinish()
        let suspensionWaitMilliseconds = Self.elapsedMilliseconds(since: suspensionWaitStartedAt)
        guard phaseOwnsLiveRuntime, ownsForegroundActivation(id: activationID) else { return }

        let isRestartingAfterSuspension = runtimeSuspendedForBackground || client == nil
        var constructionMilliseconds = 0.0
        var startMilliseconds = 0.0
        if isRestartingAfterSuspension {
            isRuntimeWarmingUp = true
        }
        // Cleared on success, cancellation, and failure exits so a failed
        // resume doesn't strand the "Connecting…" chrome on.
        defer {
            if isRestartingAfterSuspension {
                isRuntimeWarmingUp = false
            }
        }

        if isRestartingAfterSuspension {
            do {
                let constructionStartedAt = ContinuousClock.now
                var restored = try await makeRuntime(
                    retryOnTransientReadiness: true,
                    stillOwnsWork: { self.ownsForegroundActivation(id: activationID) }
                )
                constructionMilliseconds = Self.elapsedMilliseconds(since: constructionStartedAt)
#if DEBUG
                if let afterForegroundRuntimeCreatedForTesting {
                    await afterForegroundRuntimeCreatedForTesting()
                }
#endif
                guard ownsForegroundActivation(id: activationID) else {
                    self.attachmentPolicyBridge.detach(client: restored)
                    try? await runtimeCloser(restored)
                    return
                }
                do {
                    let startStartedAt = ContinuousClock.now
                    var retryIndex = 0
                    while true {
                        do {
                            try await runtimeStarter(restored)
                            break
                        } catch let error as MarmotKitError
                            where error.isTransientStartupReadinessFailure {
                            guard ownsForegroundActivation(id: activationID),
                                  retryIndex < constructionRetryPolicy.delays.count
                            else { throw error }
                            self.attachmentPolicyBridge.detach(client: restored)
                            try? await runtimeCloser(restored)
                            let delay = constructionRetryPolicy.delays[retryIndex]
                            retryIndex += 1
                            try await retrySleeper(delay)
                            restored = try await makeRuntime(
                                retryOnTransientReadiness: true,
                                stillOwnsWork: { self.ownsForegroundActivation(id: activationID) }
                            )
                        }
                    }
                    startMilliseconds = Self.elapsedMilliseconds(since: startStartedAt)
                    recordHostPerformance(using: restored, operation: .runtimeInit, since: constructionStartedAt, outcome: .success)
                } catch {
                    recordHostPerformance(using: restored, operation: .runtimeInit, since: constructionStartedAt,
                                          outcome: error is CancellationError ? .cancelled : .failure)
                    if !(error is CancellationError), ownsForegroundActivation(id: activationID) {
                        recordHostPerformance(
                            using: restored,
                            operation: .foregroundLocalReady,
                            since: resumeStartedAt,
                            outcome: .failure
                        )
                    }
                    self.attachmentPolicyBridge.detach(client: restored)
                    try? await runtimeCloser(restored)
                    if ownsForegroundActivation(id: activationID) {
                        appState?.stopNotificationSubscription()
                        await appState?.cancelNativePushRegistrationTask()
                        appState?.setPhase(.failed(UserFacingError.message(for: error)))
                    }
                    return
                }
                guard ownsForegroundActivation(id: activationID) else {
                    self.attachmentPolicyBridge.detach(client: restored)
                    try? await runtimeCloser(restored)
                    return
                }
                client = restored
                startedClientID = ObjectIdentifier(restored)
                // An import may have persisted its identity just before suspension.
                // Recover its checkpoint before restarting account maintenance.
                let accountLoadStartedAt = ContinuousClock.now
                do {
                    if let appState {
                        try await refreshAccountsForBootstrap(appState, stillOwnsWork: {
                            self.ownsForegroundActivation(id: activationID)
                        })
                    }
                    guard ownsForegroundActivation(id: activationID) else { throw CancellationError() }
                    recordHostPerformance(using: restored, operation: .accountLoad, since: accountLoadStartedAt, outcome: .success)
                } catch {
                    recordHostPerformance(using: restored, operation: .accountLoad, since: accountLoadStartedAt,
                                          outcome: error is CancellationError ? .cancelled : .failure)
                    // Close this activation's handle even if ownership changed during refresh.
                    if client === restored {
                        client = nil
                        startedClientID = nil
                    }
                    self.attachmentPolicyBridge.detach(client: restored)
                    try? await runtimeCloser(restored)
                    if ownsForegroundActivation(id: activationID), !(error is CancellationError) {
                        appState?.setPhase(.failed(UserFacingError.message(for: error)))
                    }
                    return
                }
                noteRuntimeForegroundReadyAfterSuspension()
                await appState?.refreshProductAnalytics()
                // `startRuntime()` returns after local hydration and account
                // command-readiness. Marmot's initial relay sync continues
                // asynchronously, so local conversations can be shown now.
                isRuntimeWarmingUp = false
                recordHostPerformance(
                    using: restored,
                    operation: .foregroundLocalReady,
                    since: resumeStartedAt,
                    outcome: .success
                )
                // The notification subscription needs an active account, so it
                // only belongs to `.ready`. An `.onboarding` resume rebuilds the
                // runtime (releasing the suspended App Group SQLite lock) but
                // mirrors `performBootstrap`'s onboarding branch, which starts no
                // subscription. The subscription begins when onboarding completes
                // via `startReadyForegroundMaintenance()` (#338).
                if appState?.erasureState.blocksNormalAccountActivation == true {
                    appState?.activeAccountRef = nil
                    if let appState, !appState.accounts.contains(where: { !$0.signedOut }) {
                        appState.setPhase(.onboarding)
                    }
                } else if appState?.phase == .ready {
                    appState?.startNotificationSubscription()
                }
            } catch {
                // Runtime construction failed before a handle existed. Only the
                // owning foreground activation should surface the startup error.
                if ownsForegroundActivation(id: activationID) {
                    appState?.stopNotificationSubscription()
                    await appState?.cancelNativePushRegistrationTask()
                    appState?.setPhase(.failed(UserFacingError.message(for: error)))
                }
                return
            }
        }

        guard ownsForegroundActivation(id: activationID) else { return }
        // Keep surviving accounts out of foreground maintenance — including on
        // live-client `.inactive` -> `.active` transitions — while erasure
        // recovery is pending.
        if appState?.erasureState.blocksNormalAccountActivation == true {
            appState?.activeAccountRef = nil
            return
        }
        if !isRestartingAfterSuspension {
            if appState?.phase == .ready {
                appState?.restartReadyForegroundMaintenanceIfStopped()
            }
            if isCurrentClientStarted,
               let client,
               !self.attachmentPolicyBridge.isAttached(to: client) {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.client === client,
                          self.isCurrentClientStarted,
                          self.canUseLiveRuntime
                    else { return }
                    _ = try? await self.attachmentPolicyBridge.synchronize(client)
                }
            }
        }
        Self.foregroundResumeLog.info(
            """
            local_ready restarted=\(isRestartingAfterSuspension, privacy: .public) \
            wait_for_suspension_ms=\(suspensionWaitMilliseconds, format: .fixed(precision: 0), privacy: .public) \
            runtime_construction_ms=\(constructionMilliseconds, format: .fixed(precision: 0), privacy: .public) \
            runtime_start_ms=\(startMilliseconds, format: .fixed(precision: 0), privacy: .public) \
            total_ms=\(Self.elapsedMilliseconds(since: resumeStartedAt), format: .fixed(precision: 0), privacy: .public)
            """
        )
        // The remaining maintenance is account-scoped and no-ops safely in
        // `.onboarding`: foreground catch-up is `.ready`-gated by
        // `ForegroundNotificationSyncPolicy`, and the push-registration / profile
        // queue paths find no accounts to act on while onboarding.
        //
        // Reuse the coordinator-owned connectivity task. Suspension cancels and
        // drains this task before releasing the client, while a stale/inactive
        // activation is rejected by the coordinator's foreground gate.
        appState?.scheduleConnectivityCatchUp()
        appState?.scheduleNativePushRegistrationIfEnabled()
        appState?.resumeProfileFetchQueueIfNeeded()
        appState?.scheduleAccountUnreadSummaryRefresh()
        appState?.startRetentionSweeps()
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    }

    private func recordHostPerformance(
        using client: MarmotClient,
        operation: HostPerformanceOperationFfi,
        since start: ContinuousClock.Instant,
        outcome: HostPerformanceOutcomeFfi
    ) {
        let durationMs = UInt64(max(0, Self.elapsedMilliseconds(since: start)).rounded())
        if operation == .splashReady || operation == .foregroundLocalReady {
            appState?.productAnalytics.record(.ready(success: outcome == .success, milliseconds: durationMs))
        }
        hostPerformanceRecorder(client, operation, durationMs, outcome)
    }

    private func ownsForegroundActivation(id: UUID) -> Bool {
        foregroundActivationTaskID == id && isAppSceneActive && !Task.isCancelled
    }

    // MARK: - Background notification actions

    /// Runtime for a notification action (reply / mark-read), which can arrive
    /// while the app is foregrounded, backgrounded with the runtime suspended,
    /// or launched UI-less in the background before bootstrap has run. With a
    /// live foreground client, the action leases that durable runtime.
    /// Otherwise the lease owns an exclusive ephemeral runtime with `.frozen`
    /// cursor persistence: it still ingests, decrypts, and publishes, but
    /// cannot ratchet the durable transport-cursor floor past events a short
    /// background pass did not receive. It is never assigned to the client
    /// slot and never survives into foreground use, so a foregrounded app
    /// cannot end up running indefinitely on a frozen cursor. The suspension
    /// claim is held for the whole action; a foreground activation or bootstrap
    /// that lands mid-action parks on the waiter machinery for the action's
    /// duration (seconds) and then resumes with a fresh durable runtime.
    func setNotificationActionBackgroundEntryHandler(
        actionID: UUID,
        handler: @escaping @MainActor () -> Void
    ) {
        notificationActionBackgroundEntryHandler = (actionID: actionID, handler: handler)
    }

    func clearNotificationActionBackgroundEntryHandler(actionID: UUID) {
        guard notificationActionBackgroundEntryHandler?.actionID == actionID else { return }
        notificationActionBackgroundEntryHandler = nil
    }

    private func notifyNotificationActionBackgroundEntry() {
        notificationActionBackgroundEntryHandler?.handler()
    }

    private var canHostEphemeralNotificationActionRuntime: Bool {
        appState?.blocksAccountWork != true
            && ((phaseOwnsLiveRuntime && runtimeSuspendedForBackground)
                || (appState?.phase == .bootstrapping && client == nil && bootstrapTask == nil))
    }

    func startRuntimeForNotificationAction(
        actionID: UUID = UUID()
    ) async throws -> NotificationActionRuntimeLease {
        // Let any in-flight foreground activation, suspension, bootstrap,
        // release, or earlier notification action finish first so we never
        // construct a second runtime over the same App Group store concurrently.
        while true {
            guard !Task.isCancelled else {
                throw NotificationActionError.runtimeUnavailable
            }
            if let activation = foregroundActivationTask {
                await activation.value
                continue
            }
            if let suspension = runtimeSuspensionTask {
                await suspension.value
                continue
            }
            if let bootstrapTask {
                await bootstrapTask.value
                continue
            }
            if notificationActionReleaseTask != nil {
                await waitForNotificationActionReleaseToFinish()
                continue
            }
            if runtimeWorkIsSuspending {
                await waitForRuntimeSuspensionToFinish()
                continue
            }
            break
        }
        let canUseLiveClient = phaseOwnsLiveRuntime && !runtimeSuspendedForBackground && client != nil
        let canUseEphemeralClient = canHostEphemeralNotificationActionRuntime
        guard (canUseLiveClient || canUseEphemeralClient),
              appState?.blocksAccountWork != true,
              !Task.isCancelled
        else {
            throw NotificationActionError.runtimeUnavailable
        }
        // Both lease kinds claim the same suspension gate for the full action.
        // The live-client branch needs this too: its FFI work must finish before
        // a concurrent background transition can tear the durable runtime down.
        isRuntimeSuspending = true
        if canUseLiveClient, let client {
            let lease = NotificationActionRuntimeLease(
                actionID: actionID,
                client: client,
                ownsEphemeralRuntime: false
            )
            activeNotificationActionLease = lease
            return lease
        }
        let start = PendingNotificationActionStart(actionID: actionID)
        pendingNotificationActionStart = start
        func abandonPendingStart(_ error: Error) async throws -> Never {
            // Once `expireActiveNotificationAction` marks the start expired, it
            // owns closing any late-built client under the action's deadline
            // barrier; don't race it for `takeEphemeralClientForRelease()`.
            if !start.isExpired, let clientToClose = start.takeEphemeralClientForRelease() {
                await runNotificationActionRelease(actionID: actionID) { [self] in
                    _ = try? await clientToClose.marmot.shutdownAndClose()
                    releasePendingNotificationActionStartIfCurrent(start)
                }
            } else {
                releasePendingNotificationActionStartIfCurrent(start)
            }
            throw error
        }
        let constructionTask = Task { @MainActor [weak self] () -> Result<MarmotClient, Error> in
            guard let self else { return .failure(NotificationActionError.runtimeUnavailable) }
            do {
                let built = try await self.makeRuntime(
                    cursorPersistence: .frozen,
                    retryOnTransientReadiness: false,
                    stillOwnsWork: {
                        self.canHostEphemeralNotificationActionRuntime
                            && !start.isExpired
                            && !Task.isCancelled
                    }
                )
                start.setEphemeralClient(built)
                return .success(built)
            } catch {
                return .failure(error)
            }
        }
        start.constructionTask = constructionTask
        let constructionResult = await withTaskCancellationHandler {
            await constructionTask.value
        } onCancel: {
            constructionTask.cancel()
        }
        let ephemeral: MarmotClient
        switch constructionResult {
        case .success(let built):
            ephemeral = built
        case .failure(let error as MarmotKitError) where error.isRuntimeOwnershipContention:
            releasePendingNotificationActionStartIfCurrent(start)
            Self.runtimeOwnershipLog.info(
                "contention_fallback operation=notification_action attempt=1"
            )
            throw NotificationActionError.runtimeUnavailable
        case .failure(let error):
            releasePendingNotificationActionStartIfCurrent(start)
            throw error
        }
        guard !start.isExpired, pendingNotificationActionStart === start, !Task.isCancelled else {
            try await abandonPendingStart(NotificationActionError.runtimeUnavailable)
        }
        do {
            try await runtimeStarter(ephemeral)
        } catch {
            try await abandonPendingStart(error)
        }
        guard !start.isExpired,
              pendingNotificationActionStart === start,
              appState?.blocksAccountWork != true,
              !Task.isCancelled,
              let readyClient = start.takeEphemeralClientForRelease()
        else {
            try await abandonPendingStart(NotificationActionError.runtimeUnavailable)
        }
        // `client` stays nil and durable lifecycle state stays untouched:
        // neither a suspended runtime nor a cold `.bootstrapping` launch adopts
        // a frozen client (no generation bump).
        let lease = NotificationActionRuntimeLease(
            actionID: actionID,
            client: readyClient,
            ownsEphemeralRuntime: true
        )
        pendingNotificationActionStart = nil
        activeNotificationActionLease = lease
        return lease
    }

    private func releasePendingNotificationActionStartIfCurrent(_ start: PendingNotificationActionStart) {
        guard pendingNotificationActionStart === start else { return }
        pendingNotificationActionStart = nil
        finishRuntimeSuspensionWait()
    }

    /// Ends a notification-action lease. An ephemeral lease shuts its frozen
    /// runtime down unconditionally — it must never outlive the action — then
    /// both lease kinds release the suspension claim. A live-client lease also
    /// awaits terminal SQLCipher closure inside this same release task whenever
    /// the app is backgrounded or launched UI-less, so deadline expiration
    /// keeps the UIKit background assertion alive until storage closes.
    func suspendRuntimeAfterNotificationAction(_ lease: NotificationActionRuntimeLease) async {
        guard activeNotificationActionLease === lease else { return }
        await runNotificationActionRelease(actionID: lease.actionID) { [self] in
            await releaseNotificationActionClient(lease)
            if activeNotificationActionLease === lease {
                activeNotificationActionLease = nil
                finishRuntimeSuspensionWait()
            }
            // A live-client lease needs the action's UIKit background assertion
            // to stay alive until SQLCipher closes whenever the app is
            // backgrounded: either starting teardown on a pre-bootstrapped
            // UI-less launch (where no scene will deliver `.background`), or
            // joining an in-flight scene suspension (in case UIKit denied the
            // scene's own assertion). Wait only for terminal storage closure
            // (independent of unrelated `pendingMaintenanceDrains`) to avoid
            // drain cycles.
            if !lease.ownsEphemeralRuntime {
                if !sceneHasReportedPhase {
                    let (_, closeID) = startRuntimeSuspensionWithCloseID()
                    if let closeID {
                        await waitForBackgroundStorageClose(suspensionID: closeID)
                    }
                } else if let closeID = runtimeSuspensionClosePendingID,
                          backgroundSuspensionRequested || isBackgroundStorageCloseInProgress {
                    await waitForBackgroundStorageClose(suspensionID: closeID)
                }
            }
        }
        if lease.ownsEphemeralRuntime, hasReportedActiveScene {
            startForegroundActivation()
        }
    }

    /// Terminates an action that outlived its UIKit/background deadline. Swift
    /// task cancellation cannot interrupt every generated Rust future, so the
    /// lifecycle owner must close the runtime concurrently and only then release
    /// the suspension gate. Scoped to `actionID` so an expiring queued action
    /// never tears down a different action's pending start, close, or lease.
    func expireActiveNotificationAction(actionID: UUID) async {
        if let notificationActionReleaseTask,
           notificationActionReleaseActionID == actionID {
            await notificationActionReleaseTask.value
            return
        }
        if let pendingStart = pendingNotificationActionStart,
           pendingStart.actionID == actionID {
            pendingStart.isExpired = true
            pendingNotificationActionStart = nil
            await runNotificationActionRelease(actionID: pendingStart.actionID) { [self] in
                if let clientToClose = pendingStart.takeEphemeralClientForRelease() {
                    _ = try? await clientToClose.marmot.shutdownAndClose()
                } else if let constructionTask = pendingStart.constructionTask {
                    constructionTask.cancel()
                    _ = await constructionTask.value
                    if let clientToClose = pendingStart.takeEphemeralClientForRelease() {
                        _ = try? await clientToClose.marmot.shutdownAndClose()
                    }
                }
                finishRuntimeSuspensionWait()
            }
            if hasReportedActiveScene {
                startForegroundActivation()
            }
            return
        }
        guard let lease = activeNotificationActionLease,
              lease.actionID == actionID else {
            return
        }
        activeNotificationActionLease = nil
        guard let clientToClose = lease.takeClientForRelease() else {
            finishRuntimeSuspensionWait()
            return
        }

        if !lease.ownsEphemeralRuntime,
           client.map(ObjectIdentifier.init) == lease.clientIdentity {
            self.attachmentPolicyBridge.detach(client: clientToClose)
            client = nil
            startedClientID = nil
        }
        await runNotificationActionRelease(actionID: lease.actionID) { [self] in
            _ = try? await clientToClose.marmot.shutdownAndClose()
            if !lease.ownsEphemeralRuntime {
                runtimeSuspendedForBackground = true
            }
            finishRuntimeSuspensionWait()
        }

        if hasReportedActiveScene {
            startForegroundActivation()
        }
    }

    private func runNotificationActionRelease(
        actionID: UUID,
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        let releaseID = UUID()
        notificationActionReleaseTaskID = releaseID
        notificationActionReleaseActionID = actionID
        let releaseTask = Task { @MainActor in
            defer {
                if self.notificationActionReleaseTaskID == releaseID {
                    self.notificationActionReleaseTask = nil
                    self.notificationActionReleaseActionID = nil
                    self.resumeNotificationActionReleaseWaitersIfReady()
                }
            }
            await operation()
        }
        notificationActionReleaseTask = releaseTask
        await releaseTask.value
    }

    private func waitForRuntimeWorkAndActionReleaseToFinish() async {
        while (notificationActionReleaseTask != nil || runtimeWorkIsSuspending), !Task.isCancelled {
            if notificationActionReleaseTask != nil {
                await waitForNotificationActionReleaseToFinish()
            } else {
                await waitForRuntimeSuspensionToFinish()
            }
        }
    }

    private func waitForNotificationActionReleaseToFinish() async {
        await waitWhile(
            { self.notificationActionReleaseTask != nil },
            in: \.notificationActionReleaseWaiters
        )
    }

    private func resumeNotificationActionReleaseWaitersIfReady() {
        guard notificationActionReleaseTask == nil else { return }
        resumeAllWaiters(in: \.notificationActionReleaseWaiters)
    }

    private func waitForBackgroundStorageClose(suspensionID: UUID) async {
        await waitWhile(
            { self.runtimeSuspensionClosePendingID == suspensionID },
            in: \.backgroundStorageCloseWaiters
        )
    }

    private func markSuspensionStorageCloseFinished(suspensionID: UUID) {
        guard runtimeSuspensionClosePendingID == suspensionID else { return }
        runtimeSuspensionClosePendingID = nil
        resumeAllWaiters(in: \.backgroundStorageCloseWaiters)
    }

    private func waitWhile(
        _ condition: () -> Bool,
        in waitersKeyPath: ReferenceWritableKeyPath<RuntimeLifecycle, [UUID: CheckedContinuation<Void, Never>]>
    ) async {
        while condition(), !Task.isCancelled {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard condition(), !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    self[keyPath: waitersKeyPath][waiterID] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?[keyPath: waitersKeyPath].removeValue(forKey: waiterID)?.resume()
                }
            }
        }
    }

    private func resumeAllWaiters(
        in waitersKeyPath: ReferenceWritableKeyPath<RuntimeLifecycle, [UUID: CheckedContinuation<Void, Never>]>
    ) {
        let waiters = Array(self[keyPath: waitersKeyPath].values)
        self[keyPath: waitersKeyPath].removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func releaseNotificationActionClient(
        _ lease: NotificationActionRuntimeLease
    ) async {
        guard let clientToRelease = lease.takeClientForRelease() else { return }
        if lease.ownsEphemeralRuntime {
            try? await clientToRelease.marmot.shutdownAndClose()
        }
    }

    private func noteRuntimeForegroundReadyAfterSuspension() {
        guard runtimeSuspendedForBackground || runtimeWorkIsSuspending else { return }
        runtimeSuspendedForBackground = false
        finishRuntimeSuspensionWait()
        runtimeGeneration += 1
    }

    private func waitForRuntimeSuspensionToFinish() async {
        await waitWhile(
            { self.runtimeWorkIsSuspending },
            in: \.runtimeSuspensionWaiters
        )
    }

    private func finishRuntimeSuspensionWait() {
        isRuntimeSuspending = false
        resumeRuntimeSuspensionWaitersIfReady()
    }

    private func finishBackgroundStorageClose() {
        isBackgroundStorageCloseInProgress = false
        resumeRuntimeSuspensionWaitersIfReady()
    }

    private func waitForSuspensionStorageCloseToFinish() async {
        while (runtimeSuspensionTask != nil || runtimeWorkIsSuspending), !Task.isCancelled {
            let waiterID = UUID()

            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard runtimeSuspensionTask != nil || runtimeWorkIsSuspending,
                          !Task.isCancelled
                    else {
                        continuation.resume()
                        return
                    }
                    suspensionStorageCloseWaiters[waiterID] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.suspensionStorageCloseWaiters.removeValue(forKey: waiterID)?.resume()
                }
            }
        }
    }

    private func resumeSuspensionStorageCloseWaitersIfReady() {
        guard runtimeSuspensionTask == nil, !runtimeWorkIsSuspending else { return }
        let waiters = Array(suspensionStorageCloseWaiters.values)
        suspensionStorageCloseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeRuntimeSuspensionWaitersIfReady() {
        guard !runtimeWorkIsSuspending else { return }
        resumeAllWaiters(in: \.runtimeSuspensionWaiters)
        resumeSuspensionStorageCloseWaitersIfReady()
    }

    func beginForegroundRuntimeMutation() throws -> ForegroundRuntimeMutationLease {
        guard phaseOwnsLiveRuntime,
              canUseLiveRuntime,
              appState?.blocksAccountWork != true,
              let client
        else { throw ForegroundRuntimeMutationError.runtimeUnavailable }

        let id = UUID()
        foregroundMutationLeaseIDs.insert(id)
        return ForegroundRuntimeMutationLease(id: id, client: client)
    }

    /// Joins any foreground runtime rebuild before leasing it for an explicit
    /// user action. A tap can arrive just after the scene becomes active but
    /// before the asynchronous resume task has restored the durable runtime.
    /// Claiming foreground activation here is safe because this path is only
    /// called from a visible, user-initiated identity import.
    func beginUserInitiatedForegroundRuntimeMutation() async throws -> ForegroundRuntimeMutationLease {
        guard appState?.blocksAccountWork != true else {
            throw ForegroundRuntimeMutationError.runtimeUnavailable
        }
        if let lease = try? beginForegroundRuntimeMutation() {
            return lease
        }
        await startForegroundActivation().value
        return try beginForegroundRuntimeMutation()
    }

    func endForegroundRuntimeMutation(_ lease: ForegroundRuntimeMutationLease) {
        guard foregroundMutationLeaseIDs.remove(lease.id) != nil,
              foregroundMutationLeaseIDs.isEmpty
        else { return }

        resumeAllForegroundMutationWaiters()
    }

    private func resumeAllForegroundMutationWaiters() {
        let waiters = Array(foregroundMutationWaiters.values)
        foregroundMutationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForForegroundRuntimeMutations(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var timedOut = false
        while !foregroundMutationLeaseIDs.isEmpty,
              !Task.isCancelled,
              backgroundSuspensionRequested,
              !timedOut {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            let waiterID = UUID()
            let sleeper = mutationDrainSleeper
            var timeoutTask: Task<Void, Never>?
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !foregroundMutationLeaseIDs.isEmpty,
                          !Task.isCancelled,
                          backgroundSuspensionRequested,
                          !timedOut
                    else {
                        continuation.resume()
                        return
                    }
                    foregroundMutationWaiters[waiterID] = continuation
                    timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await sleeper(remaining)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        timedOut = true
                        self?.resumeForegroundMutationWaiter(id: waiterID)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resumeForegroundMutationWaiter(id: waiterID)
                }
            }
            timeoutTask?.cancel()
        }
    }

    private func waitForForegroundRuntimeMutations() async {
        while !foregroundMutationLeaseIDs.isEmpty {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !foregroundMutationLeaseIDs.isEmpty, !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    foregroundMutationWaiters[waiterID] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resumeForegroundMutationWaiter(id: waiterID)
                }
            }
        }
    }

    private func resumeForegroundMutationWaiter(id: UUID) {
        foregroundMutationWaiters.removeValue(forKey: id)?.resume()
    }

    private func beginForegroundMaintenanceCancellation() -> ForegroundMaintenanceCancellation {
        let foregroundTask = foregroundActivationTask
        foregroundActivationTask = nil
        foregroundActivationTaskID = UUID()
        foregroundTask?.cancel()

        // Native-push cancellation/drain stays in `NotificationCoordinator`
        // (master #401). Cancel-without-awaiting first, cancel the profile queue,
        // then drain the foreground task, the coordinator push task, and the
        // profile task — mirroring AppState's pre-extraction ordering.
        return ForegroundMaintenanceCancellation(
            foregroundActivation: foregroundTask,
            maintenance: appState?.beginForegroundMaintenanceCancellation()
        )
    }

    private func drainForegroundMaintenance(
        _ cancellation: ForegroundMaintenanceCancellation
    ) async {
        await cancellation.foregroundActivation?.value
        await cancellation.maintenance?.notificationSubscription?.value
        await cancellation.maintenance?.connectivityCatchUp?.value
        await appState?.cancelNativePushRegistrationTask()
        await appState?.cancelRetentionSweeps()
        await appState?.drainUnreadSummaryRefresh()
        await appState?.pendingAccountSetup?.drain()
        await cancellation.maintenance?.profileRefresh?.value
        if let mutationFollowups = cancellation.maintenance?.mutationFollowups {
            for task in mutationFollowups {
                await task.value
            }
        }
        // Explicit foreground mutations may still own spent handles. Terminal
        // close makes their eventual completion safe to await without risking a
        // shared-container lock at process suspension. Account-exit wait runs
        // after the storage-close gate releases to avoid deadlocking erasure.
        await waitForForegroundRuntimeMutations()
    }

    private func clearCompletedForegroundActivationTask(id: UUID) {
        guard foregroundActivationTaskID == id else { return }
        foregroundActivationTask = nil
    }

    private var phaseOwnsLiveRuntime: Bool {
        appState?.phaseOwnsLiveRuntime ?? false
    }
}
