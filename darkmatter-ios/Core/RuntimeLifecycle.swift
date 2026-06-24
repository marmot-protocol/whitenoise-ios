import Foundation
import Observation
import MarmotKit

/// Owns the Marmot runtime's lifecycle: the live `MarmotClient` handle, the
/// foreground/suspension gates, the runtime generation token, bootstrap, and the
/// background suspend / foreground resume orchestration (including the
/// suspension-waiter machinery and the lifecycle `Task`s).
///
/// Carved out of `AppState` (Phase 2). `AppState` keeps thin forwarding
/// properties/methods (`client`, `marmot`, `runtimeGeneration`,
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
    /// The live FFI runtime. Released (`nil`) while the app is suspended in the
    /// background so its SQLite storage in the shared App Group container is
    /// closed and its file lock freed — otherwise iOS terminates the app at
    /// suspension with `0xdead10cc` ("held a file lock in a shared container").
    /// Rebuilt on foreground in `resumeAfterForegroundActivation`.
    @ObservationIgnored private(set) var client: MarmotClient?
    @ObservationIgnored private let runtimeRootPath: String
    @ObservationIgnored private let runtimeRelayUrls: [String]
    @ObservationIgnored private let suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapTaskID = UUID()
    @ObservationIgnored private var foregroundActivationTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeSuspensionTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeSuspensionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Observed (like the original AppState stored flag) so the foreground/local
    /// runtime gates that fold it in stay reactive.
    private var isRuntimeSuspending = false
    private(set) var runtimeSuspendedForBackground = false
    /// True while the runtime is being (re)started after a background
    /// suspension. During this window the account worker is still hydrating and
    /// running its initial relay catch-up, so live reads (timeline tail, group
    /// roster) are briefly blocked. Conversation chrome surfaces a "Connecting…"
    /// status off this flag instead of appearing frozen. MainActor-owned.
    private(set) var isRuntimeWarmingUp = false
    private(set) var runtimeGeneration = 0

    @ObservationIgnored private weak var appState: AppState?

    init(
        client: MarmotClient,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig
    ) {
        self.client = client
        self.runtimeRootPath = client.rootPath
        self.runtimeRelayUrls = client.relayUrls
        self.suspendedRuntimeTelemetryBuildConfig = suspendedRuntimeTelemetryBuildConfig
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

    /// Exposes the suspension/suspended gate values to the notification and
    /// settings read gates that stay on `AppState`.
    var isRuntimeSuspendingNow: Bool { isRuntimeSuspending }

    // MARK: - Runtime ownership

    func runtimeClient() throws -> MarmotClient {
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
        guard let appState else { return }
        do {
            try await startCurrentRuntime()
            noteRuntimeForegroundReadyAfterSuspension()
            try await appState.refreshAccounts()
            if appState.accounts.isEmpty {
                appState.setPhase(.onboarding)
            } else {
                if appState.activeAccountRef == nil
                    || !appState.accounts.contains(where: { $0.label == appState.activeAccountRef }) {
                    appState.activeAccountRef = appState.accounts.first?.label
                }
                appState.setPhase(.ready)
                // Warm the active account's profile (name + avatar) right away
                // so it's visible without waiting for a screen to request it.
                if let activeId = appState.activeAccount?.accountIdHex {
                    appState.warmProfileProjection(forAccountIdHex: activeId, refreshAfterLoad: true)
                }
                appState.startReadyForegroundMaintenance()
            }
        } catch {
            await releaseRuntimeAfterStartupFailure()
            appState.setPhase(.failed(error.localizedDescription))
        }
    }

    /// Tear down a partially-created runtime after a failed start so the next
    /// Retry rebuilds a fresh one. Shared by the bootstrap and foreground-resume
    /// failure paths: both set `client` to a new instance and then start it, so
    /// both must release that instance (shutdown + `client = nil`) on failure —
    /// otherwise `runtimeClient()` returns the stale, broken client and Retry
    /// re-invokes `startRuntime()` on a runtime whose `start()` already failed.
    private func releaseRuntimeAfterStartupFailure() async {
        appState?.stopNotificationSubscription()
        await appState?.cancelNativePushRegistrationTask()
        if let client {
            await client.marmot.shutdown()
            self.client = nil
        }
    }

    private func clearCompletedBootstrapTask(id: UUID) {
        guard bootstrapTaskID == id else { return }
        bootstrapTask = nil
    }

    // MARK: - Foreground catch-up

    /// Foreground relay catch-up. The catch-up gate, in-flight flag, and the
    /// actual `catchUpAccounts()` FFI call live in `NotificationCoordinator`
    /// (master extracted that as part of #401); RuntimeLifecycle only sequences
    /// it from the resume path and delegates back through `AppState` so the
    /// catch-up state is not duplicated here.
    func catchUpAfterForegroundActivation() async {
        await appState?.catchUpAfterForegroundActivation()
    }

    // MARK: - Suspend / resume

    func setAppSceneActive(_ active: Bool) {
        appState?.isAppSceneActive = active
        if !active {
            foregroundActivationTask?.cancel()
            appState?.cancelNativePushRegistrationTaskSync()
        }
    }

    @discardableResult
    func startForegroundActivation() -> Task<Void, Never> {
        appState?.isAppSceneActive = true
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
        appState?.isAppSceneActive = false
        foregroundActivationTask?.cancel()
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
        await cancelForegroundMaintenance()
        // `isAppSceneActive` is owned by the synchronous scene-phase entry
        // points (`startRuntimeSuspension` / `startForegroundActivation` /
        // `setAppSceneActive`), which run in true scene-delivery order. After
        // the `await` above a racing foreground activation may have flipped the
        // scene back to active. Re-check the authoritative flag before the
        // irreversible teardown: suspending now would strand the app
        // foregrounded with `client == nil` and nothing to re-trigger resume
        // (#222). Hand back to a fresh foreground activation instead.
        guard isAppSceneActive else {
            startForegroundActivation()
            return
        }
        guard phaseOwnsLiveRuntime,
              !runtimeSuspendedForBackground,
              !isRuntimeSuspending
        else { return }

        isRuntimeSuspending = true
        defer { finishRuntimeSuspensionWait() }
        appState?.stopNotificationSubscription()
        await appState?.marmot.shutdown()
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
                if appState?.phase == .ready {
                    appState?.startNotificationSubscription()
                }
            } catch {
                // Release the partial runtime before showing the failure screen
                // so Retry → bootstrap() → runtimeClient() rebuilds a fresh
                // runtime instead of reusing this instance whose start() failed.
                await releaseRuntimeAfterStartupFailure()
                appState?.setPhase(.failed(error.localizedDescription))
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
        appState?.scheduleNativePushRegistrationIfEnabled()
        appState?.resumeProfileFetchQueueIfNeeded()
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

        // Native-push cancellation/drain stays in `NotificationCoordinator`
        // (master #401). Cancel-without-awaiting first, cancel the profile queue,
        // then drain the foreground task, the coordinator push task, and the
        // profile task — mirroring AppState's pre-extraction ordering.
        let profileTask = appState?.beginForegroundMaintenanceCancellation()

        await foregroundTask?.value
        await appState?.cancelNativePushRegistrationTask()
        await profileTask?.value
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
