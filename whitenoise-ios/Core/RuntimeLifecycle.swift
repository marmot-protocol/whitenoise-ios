import Foundation
import Observation
import OSLog
import MarmotKit

/// Runtime handle for one notification action: either the live foreground
/// client (durable) or a lease-private frozen runtime built while the app's
/// durable runtime stays suspended.
final class NotificationActionRuntimeLease {
    private var retainedClient: MarmotClient?
    let clientIdentity: ObjectIdentifier
    /// True when the lease owns a private ephemeral frozen runtime. It is
    /// never the app's client slot and must be shut down when the action
    /// completes; foreground never adopts it.
    let ownsEphemeralRuntime: Bool

    init(client: MarmotClient, ownsEphemeralRuntime: Bool) {
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
    typealias RetrySleeper = @Sendable (_ delay: Duration) async throws -> Void

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
    @ObservationIgnored private let retrySleeper: RetrySleeper
    @ObservationIgnored private let constructionRetryPolicy: RuntimeConstructionRetryPolicy

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTaskID = UUID()
    @ObservationIgnored private var foregroundActivationTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundActivationTaskID = UUID()
    @ObservationIgnored private var runtimeSuspensionTask: Task<Void, Never>?
    @ObservationIgnored private var activeNotificationActionLease: NotificationActionRuntimeLease?
    @ObservationIgnored private var notificationActionReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var notificationActionReleaseTaskID = UUID()
    @ObservationIgnored private var runtimeSuspensionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var bootstrapRegistrationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var foregroundMutationLeaseIDs: Set<UUID> = []
    @ObservationIgnored private var foregroundMutationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Set when the real background-suspension entry point runs while bootstrap
    /// still has the phase at `.bootstrapping`. An `.inactive` scene transition
    /// only flips `isAppSceneActive`; it must not tear the runtime down until the
    /// app actually reaches `.background`.
    @ObservationIgnored private var bootstrapNeedsBackgroundSuspensionRecheck = false
#if DEBUG
    @ObservationIgnored var afterBootstrapRuntimeStartForTesting: (() async -> Void)?
    @ObservationIgnored var afterForegroundRuntimeCreatedForTesting: (() async -> Void)?
    @ObservationIgnored var hostPerformanceObserverForTesting: ((
        HostPerformanceOperationFfi,
        UInt64,
        HostPerformanceOutcomeFfi
    ) -> Void)?
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
        runtimeClientFactory: @escaping RuntimeClientFactory = RuntimeLifecycle.defaultRuntimeClientFactory,
        retrySleeper: @escaping RetrySleeper = { delay in try await Task.sleep(for: delay) },
        constructionRetryPolicy: RuntimeConstructionRetryPolicy = .foreground
    ) {
        self.client = client
        self.runtimeRootPath = client?.rootPath
        self.runtimeRelayUrls = client?.relayUrls ?? MarmotClient.seedRelays
        self.suspendedRuntimeTelemetryBuildConfig = suspendedRuntimeTelemetryBuildConfig
        self.runtimeClientFactory = runtimeClientFactory
        self.retrySleeper = retrySleeper
        self.constructionRetryPolicy = constructionRetryPolicy
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

    var canRefreshProfiles: Bool {
        isAppSceneActive
            && !runtimeSuspendedForBackground
            && !runtimeWorkIsSuspending
            && client != nil
    }

    var canUseRuntimeForLocalForegroundWork: Bool {
        ForegroundRuntimeWorkGate.canUseLocalForegroundWork(
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
                return try await runtimeClientFactory(
                    rootPath,
                    relayUrls,
                    cursorPersistence,
                    telemetryConfig
                )
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
                client = try await makeRuntime(
                    retryOnTransientReadiness: true,
                    stillOwnsWork: stillOwnsWork
                )
            }
            guard let client else { throw ForegroundRuntimeMutationError.runtimeUnavailable }
            do {
                try await client.startRuntime()
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
        let bootstrapStartedAt = ContinuousClock.now
        let beganWhileInactive = appState.sceneHasReportedPhase
            && !appState.isAppSceneActive
            && !bootstrapNeedsBackgroundSuspensionRecheck
        var runtimeStartMilliseconds = 0.0
        var accountLoadMilliseconds = 0.0
        do {
            let runtimeStartStartedAt = ContinuousClock.now
            try await startCurrentRuntime {
                self.bootstrapTaskID == id
                    && !Task.isCancelled
                    && (!self.sceneHasReportedPhase
                        || self.isAppSceneActive
                        || beganWhileInactive
                        || self.bootstrapNeedsBackgroundSuspensionRecheck)
            }
            runtimeStartMilliseconds = Self.elapsedMilliseconds(since: runtimeStartStartedAt)
#if DEBUG
            if let afterBootstrapRuntimeStartForTesting {
                await afterBootstrapRuntimeStartForTesting()
            }
#endif
            noteRuntimeForegroundReadyAfterSuspension()
            let accountLoadStartedAt = ContinuousClock.now
            // Routing needs the durable account list, but unread badges do not
            // gate local conversation display. Refresh them after `.ready`.
            try await refreshAccountsForBootstrap(appState, stillOwnsWork: {
                self.bootstrapTaskID == id
                    && !Task.isCancelled
                    && (!self.sceneHasReportedPhase
                        || self.isAppSceneActive
                        || beganWhileInactive
                        || self.bootstrapNeedsBackgroundSuspensionRecheck)
            })
            accountLoadMilliseconds = Self.elapsedMilliseconds(since: accountLoadStartedAt)
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
                if appState.activeAccountRef == nil
                    || !appState.accounts.contains(where: { $0.label == appState.activeAccountRef }) {
                    appState.activeAccountRef = appState.accounts.first?.label
                }
                appState.setPhase(.ready)
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
                // Warm the active account's profile (name + avatar) right away
                // so it's visible without waiting for a screen to request it.
                if let activeId = appState.activeAccount?.accountIdHex {
                    appState.warmProfileProjection(forAccountIdHex: activeId, refreshAfterLoad: true)
                }
                appState.scheduleAccountUnreadSummaryRefresh()
                appState.startReadyForegroundMaintenance()
            }
        } catch is CancellationError {
            // Backgrounding or losing bootstrap ownership is expected
            // lifecycle control flow. Leave the phase bootstrapping so the
            // next active transition can build a fresh runtime.
            await releaseRuntimeAfterStartupFailure()
        } catch {
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
            appState.setPhase(.failed(error.localizedDescription))
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
        let shouldRearm = bootstrapNeedsBackgroundSuspensionRecheck && !isAppSceneActive
        bootstrapNeedsBackgroundSuspensionRecheck = false
        guard shouldRearm else { return false }
        startRuntimeSuspension()
        return true
    }

    private func waitForBootstrapRegistrationIfNeeded() async {
        guard bootstrapTask == nil,
              appState?.phase == .bootstrapping,
              bootstrapNeedsBackgroundSuspensionRecheck,
              !isAppSceneActive
        else { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard bootstrapTask == nil,
                      appState?.phase == .bootstrapping,
                      bootstrapNeedsBackgroundSuspensionRecheck,
                      !isAppSceneActive,
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

    private func shutdownAndReleaseCurrentClient() async {
        let clientToRelease = client
        client = nil
        guard let clientToRelease else { return }
        try? await clientToRelease.marmot.shutdownAndClose()
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
        resumeBootstrapRegistrationWaiters()
        if appState?.phase == .bootstrapping {
            return Task { [weak self] in
                guard let self else { return }
                await bootstrapTask?.value
                guard appState?.phase == .bootstrapping else { return }
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
            await resumeAfterForegroundActivation(activationID: id)
            clearCompletedForegroundActivationTask(id: id)
        }
        foregroundActivationTask = task
        return task
    }

    @discardableResult
    func startRuntimeSuspension() -> Task<Void, Never> {
        appState?.isAppSceneActive = false
        appState?.sceneHasReportedPhase = true
        if appState?.phase == .bootstrapping {
            bootstrapNeedsBackgroundSuspensionRecheck = true
        }
        foregroundActivationTask?.cancel()
        foregroundActivationTaskID = UUID()
        appState?.cancelNativePushRegistrationTaskSync()
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
        // Stop admitting foreground maintenance immediately, but do not put
        // storage closure behind cancellation-sensitive drains. A subscription,
        // relay catch-up, or local read can otherwise consume the entire UIKit
        // background assertion while SQLCipher still holds its App Group lock.
        let cancellation = beginForegroundMaintenanceCancellation()
        // `isAppSceneActive` is owned by the synchronous scene-phase entry
        // points (`startRuntimeSuspension` / `startForegroundActivation` /
        // `setAppSceneActive`), which run in true scene-delivery order. After
        // the `await` above a racing foreground activation may have flipped the
        // scene back to active. Re-check the authoritative flag before the
        // irreversible teardown: suspending now would strand the app
        // foregrounded with `client == nil` and nothing to re-trigger resume
        // (#222). Hand back to a fresh foreground activation instead.
        guard !isAppSceneActive else {
            await drainForegroundMaintenance(cancellation)
            startForegroundActivation()
            return
        }
        // A very fast launch-to-background transition can arrive before the
        // SwiftUI bootstrap task has even registered. Park this same suspension
        // owner until bootstrap exists, then chain through it; never re-arm the
        // real teardown outside the UIKit assertion attached to this task.
        if appState?.phase == .bootstrapping {
            await waitForBootstrapRegistrationIfNeeded()
            await bootstrapTask?.value
            guard !isAppSceneActive else {
                await drainForegroundMaintenance(cancellation)
                startForegroundActivation()
                return
            }
        }
        guard phaseOwnsLiveRuntime,
              !runtimeSuspendedForBackground
        else {
            await drainForegroundMaintenance(cancellation)
            return
        }

        // A notification action can hold an explicit lease on the live client.
        // Unlike cancelled maintenance, that work must retain the runtime until
        // the action releases it; closing underneath the lease would invalidate
        // an in-flight reply or mark-read FFI call. This gate is independent of
        // the maintenance drains moved below terminal storage closure.
        await waitForRuntimeSuspensionToFinish()
        guard !isAppSceneActive,
              phaseOwnsLiveRuntime,
              !runtimeSuspendedForBackground
        else {
            await drainForegroundMaintenance(cancellation)
            if isAppSceneActive {
                startForegroundActivation()
            }
            return
        }

        isBackgroundStorageCloseInProgress = true
        defer { finishBackgroundStorageClose() }
        await shutdownAndReleaseCurrentClient()
        // `shutdownAndClose()` explicitly closes every SQLite connection and
        // releases the root lease. Dropping only the top-level handle cannot
        // prove that while subscriptions and projections retain internal Arcs;
        // suspending with either lock is an iOS `0xdead10cc` kill.
        runtimeSuspendedForBackground = true
        // Once terminal storage closure has run, cancelled work can safely
        // drain: retained handles are spent and return StorageClosed instead of
        // reopening the App Group databases. Keep the lifecycle task alive so
        // foreground resume still observes orderly task completion, but the
        // suspension-sensitive file lock is already gone if UIKit expires the
        // background assertion during this cleanup.
        await drainForegroundMaintenance(cancellation)
    }

    private func resumeAfterForegroundActivation(activationID: UUID) async {
        let resumeStartedAt = ContinuousClock.now
        let suspensionWaitStartedAt = ContinuousClock.now
        await waitForRuntimeSuspensionToFinish()
        let suspensionWaitMilliseconds = Self.elapsedMilliseconds(since: suspensionWaitStartedAt)
        guard phaseOwnsLiveRuntime, ownsForegroundActivation(id: activationID) else { return }

        let isRestartingAfterSuspension = runtimeSuspendedForBackground
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
                    try? await restored.marmot.shutdownAndClose()
                    return
                }
                do {
                    let startStartedAt = ContinuousClock.now
                    var retryIndex = 0
                    while true {
                        do {
                            try await restored.startRuntime()
                            break
                        } catch let error as MarmotKitError
                            where error.isTransientStartupReadinessFailure {
                            guard ownsForegroundActivation(id: activationID),
                                  retryIndex < constructionRetryPolicy.delays.count
                            else { throw error }
                            try? await restored.marmot.shutdownAndClose()
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
                } catch {
                    if !(error is CancellationError), ownsForegroundActivation(id: activationID) {
                        recordHostPerformance(
                            using: restored,
                            operation: .foregroundLocalReady,
                            since: resumeStartedAt,
                            outcome: .failure
                        )
                    }
                    try? await restored.marmot.shutdownAndClose()
                    if ownsForegroundActivation(id: activationID) {
                        appState?.stopNotificationSubscription()
                        await appState?.cancelNativePushRegistrationTask()
                        appState?.setPhase(.failed(error.localizedDescription))
                    }
                    return
                }
                guard ownsForegroundActivation(id: activationID) else {
                    try? await restored.marmot.shutdownAndClose()
                    return
                }
                client = restored
                // An import may have persisted its identity just before suspension.
                // Recover its checkpoint before restarting account maintenance.
                try await appState?.refreshAccounts(refreshUnreadSummaries: false)
                guard ownsForegroundActivation(id: activationID) else { return }
                noteRuntimeForegroundReadyAfterSuspension()
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
                if appState?.phase == .ready {
                    appState?.startNotificationSubscription()
                }
            } catch {
                // Runtime construction failed before a handle existed. Only the
                // owning foreground activation should surface the startup error.
                if ownsForegroundActivation(id: activationID) {
                    appState?.stopNotificationSubscription()
                    await appState?.cancelNativePushRegistrationTask()
                    appState?.setPhase(.failed(error.localizedDescription))
                }
                return
            }
        }

        guard ownsForegroundActivation(id: activationID) else { return }
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
#if DEBUG
        hostPerformanceObserverForTesting?(operation, durationMs, outcome)
#endif
        client.recordHostPerformance(
            operation: operation,
            durationMs: durationMs,
            outcome: outcome
        )
    }

    private func ownsForegroundActivation(id: UUID) -> Bool {
        foregroundActivationTaskID == id && isAppSceneActive && !Task.isCancelled
    }

    // MARK: - Background notification actions

    /// Runtime for a notification action (reply / mark-read), which can arrive
    /// while the app is backgrounded and the runtime is suspended. With a live
    /// foreground client, the action leases that durable runtime. Otherwise
    /// the lease owns an exclusive ephemeral runtime with `.frozen` cursor
    /// persistence: it still ingests, decrypts, and publishes, but cannot
    /// ratchet the durable transport-cursor floor past events a short
    /// background pass did not receive. It is never assigned to the client
    /// slot and never survives into foreground use, so a foregrounded app
    /// cannot end up running indefinitely on a frozen cursor. The suspension
    /// claim is held for the whole action; a foreground activation that lands
    /// mid-action parks on the waiter machinery for the action's duration
    /// (seconds) and then resumes with a fresh durable runtime.
    func startRuntimeForNotificationAction() async throws -> NotificationActionRuntimeLease {
        // Let an in-flight foreground activation finish first so the live
        // durable client serves the action, instead of building a second
        // runtime over the same App Group store mid-activation.
        await foregroundActivationTask?.value
        await runtimeSuspensionTask?.value
        await waitForRuntimeSuspensionToFinish()
        guard phaseOwnsLiveRuntime, !Task.isCancelled else {
            throw NotificationActionError.runtimeUnavailable
        }
        // Both lease kinds claim the same suspension gate for the full action.
        // The live-client branch needs this too: its FFI work must finish before
        // a concurrent background transition can tear the durable runtime down.
        isRuntimeSuspending = true
        if !runtimeSuspendedForBackground, let client {
            let lease = NotificationActionRuntimeLease(client: client, ownsEphemeralRuntime: false)
            activeNotificationActionLease = lease
            return lease
        }
        let ephemeral: MarmotClient
        do {
            ephemeral = try await makeRuntime(
                cursorPersistence: .frozen,
                retryOnTransientReadiness: false,
                stillOwnsWork: {
                    self.phaseOwnsLiveRuntime
                        && self.runtimeSuspendedForBackground
                        && !Task.isCancelled
                }
            )
        } catch let error as MarmotKitError where error.isRuntimeOwnershipContention {
            finishRuntimeSuspensionWait()
            Self.runtimeOwnershipLog.info(
                "contention_fallback operation=notification_action attempt=1"
            )
            throw NotificationActionError.runtimeUnavailable
        } catch {
            finishRuntimeSuspensionWait()
            throw error
        }
        do {
            try await ephemeral.startRuntime()
        } catch {
            // Release the partial runtime like the bootstrap failure path.
            try? await ephemeral.marmot.shutdownAndClose()
            finishRuntimeSuspensionWait()
            throw error
        }
        guard !Task.isCancelled else {
            try? await ephemeral.marmot.shutdownAndClose()
            finishRuntimeSuspensionWait()
            throw NotificationActionError.runtimeUnavailable
        }
        // `client` stays nil and `runtimeSuspendedForBackground` stays true:
        // the app's durable runtime really is still suspended, and nothing
        // app-visible changed runtimes (no generation bump).
        let lease = NotificationActionRuntimeLease(client: ephemeral, ownsEphemeralRuntime: true)
        activeNotificationActionLease = lease
        return lease
    }

    /// Ends a notification-action lease. An ephemeral lease shuts its frozen
    /// runtime down unconditionally — it must never outlive the action — then
    /// both lease kinds release the suspension claim. A scene transition that
    /// arrived mid-action then continues through the normal suspend / resume
    /// path after re-checking the authoritative scene flag.
    func suspendRuntimeAfterNotificationAction(_ lease: NotificationActionRuntimeLease) async {
        guard activeNotificationActionLease === lease else { return }
        let releaseID = UUID()
        notificationActionReleaseTaskID = releaseID
        let releaseTask = Task {
            await self.releaseNotificationActionClient(lease)
        }
        notificationActionReleaseTask = releaseTask
        await releaseTask.value
        guard notificationActionReleaseTaskID == releaseID else { return }
        notificationActionReleaseTask = nil
        activeNotificationActionLease = nil
        finishRuntimeSuspensionWait()

        // A live-client lease on a cold UI-less launch rides the runtime that
        // the action's own bootstrap started. With no scene transition to own
        // teardown, suspend it here after releasing the lease gate.
        if !sceneHasReportedPhase {
            await startRuntimeSuspension().value
        } else if lease.ownsEphemeralRuntime, isAppSceneActive {
            startForegroundActivation()
        }
    }

    /// Terminates an action that outlived its UIKit/background deadline. Swift
    /// task cancellation cannot interrupt every generated Rust future, so the
    /// lifecycle owner must close the runtime concurrently and only then release
    /// the suspension gate. A foreground app rebuilds a fresh durable runtime;
    /// a background app remains safely suspended with storage closed.
    func expireActiveNotificationAction() async {
        if let notificationActionReleaseTask {
            await notificationActionReleaseTask.value
            return
        }
        guard let lease = activeNotificationActionLease else {
            await runtimeSuspensionTask?.value
            return
        }
        activeNotificationActionLease = nil
        guard let clientToClose = lease.takeClientForRelease() else {
            finishRuntimeSuspensionWait()
            return
        }

        if !lease.ownsEphemeralRuntime,
           client.map(ObjectIdentifier.init) == lease.clientIdentity {
            client = nil
        }
        try? await clientToClose.marmot.shutdownAndClose()
        if !lease.ownsEphemeralRuntime {
            runtimeSuspendedForBackground = true
        }
        finishRuntimeSuspensionWait()

        if isAppSceneActive {
            startForegroundActivation()
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
        while runtimeWorkIsSuspending, !Task.isCancelled {
            let waiterID = UUID()

            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard runtimeWorkIsSuspending, !Task.isCancelled else {
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
    }

    private func finishRuntimeSuspensionWait() {
        isRuntimeSuspending = false
        resumeRuntimeSuspensionWaitersIfReady()
    }

    private func finishBackgroundStorageClose() {
        isBackgroundStorageCloseInProgress = false
        resumeRuntimeSuspensionWaitersIfReady()
    }

    private func resumeRuntimeSuspensionWaitersIfReady() {
        guard !runtimeWorkIsSuspending else { return }
        let waiters = Array(runtimeSuspensionWaiters.values)
        runtimeSuspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeRuntimeSuspensionWaiter(id: UUID) {
        runtimeSuspensionWaiters.removeValue(forKey: id)?.resume()
    }

    func beginForegroundRuntimeMutation() throws -> ForegroundRuntimeMutationLease {
        guard phaseOwnsLiveRuntime,
              canUseRuntimeForLocalForegroundWork,
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

        let waiters = Array(foregroundMutationWaiters.values)
        foregroundMutationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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
        // Sign-out/wipe and explicit foreground mutations may still own spent
        // handles. Terminal close makes their eventual completion safe to await
        // without risking a shared-container lock at process suspension.
        await appState?.waitForAccountExitToFinish()
        await waitForForegroundRuntimeMutations()
    }

    private func clearCompletedForegroundActivationTask(id: UUID) {
        guard foregroundActivationTaskID == id else { return }
        foregroundActivationTask = nil
    }

    private var phaseOwnsLiveRuntime: Bool {
        appState?.phaseOwnsLiveRuntime ?? false
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
        await appState?.nativePushRegistrationTaskValueForTesting()
    }
    #endif
}
