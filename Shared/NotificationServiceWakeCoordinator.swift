import Foundation
import MarmotKit
import OSLog
import Synchronization
import UserNotifications

/// Minimal runtime surface owned by one Notification Service Extension wake.
/// `LiveNotificationServiceWakeRuntime` wraps `Marmot` in production; unit tests
/// inject a fake to verify per-wake isolation and shutdown ordering.
nonisolated protocol NotificationServiceWakeRuntime: AnyObject, Sendable {
    func setAuditLogSource(source: AuditLogSourceFfi) throws
    func start() async throws
    func collectNotificationsAfterWake(
        maxWaitMs: UInt32,
        source: NotificationWakeSourceFfi
    ) async throws -> BackgroundNotificationCollectionFfi
    func applicationBadgeCount() async -> Int?
    func localNotificationsEnabled(accountRefs: Set<String>) async -> [String: Bool]
    func archivedChatKeys(accountRefs: Set<String>) async -> Set<String>
    func shutdownAndClose() async throws
}

nonisolated final class LiveNotificationServiceWakeRuntime: NotificationServiceWakeRuntime {
    private let marmot: Marmot

    init() throws {
        // An NSE wake is a sub-second drain on cold sockets; it must never
        // persist cursor advancement, or a partial catch-up permanently
        // floors the durable `since` past undelivered events.
        marmot = try Marmot.newWithConfiguration(
            rootPath: AppContainerConfig.productionMarmotRoot().path,
            relayUrls: AppContainerConfig.seedRelays,
            options: MarmotOptions(
                cursorPersistence: .frozen,
                clientName: "whitenoise",
                devicePlatform: AppContainerConfig.marmotDevicePlatform,
                attachmentAcquisitionMode: .hostManaged,
                deployment: marmotDeploymentWhiteNoise()
            )
        )
    }

    func setAuditLogSource(source: AuditLogSourceFfi) throws {
        _ = try marmot.setAuditLogSource(source: source)
    }

    func start() async throws {
        try await marmot.start()
    }

    func collectNotificationsAfterWake(
        maxWaitMs: UInt32,
        source: NotificationWakeSourceFfi
    ) async throws -> BackgroundNotificationCollectionFfi {
        try await marmot.collectNotificationsAfterWake(maxWaitMs: maxWaitMs, source: source)
    }

    func applicationBadgeCount() async -> Int? {
        await NotificationServiceStorageReader.applicationBadgeCount(marmot: marmot)
    }

    func localNotificationsEnabled(accountRefs: Set<String>) async -> [String: Bool] {
        await NotificationServiceStorageReader.localNotificationsEnabled(
            marmot: marmot,
            accountRefs: accountRefs
        )
    }

    func archivedChatKeys(accountRefs: Set<String>) async -> Set<String> {
        await NotificationServiceStorageReader.archivedChatKeys(
            marmot: marmot,
            accountRefs: accountRefs
        )
    }

    func shutdownAndClose() async throws {
        try await marmot.shutdownAndClose()
    }
}

/// Snapshot of shared-container preferences read once per NSE wake so
/// archived-lookup prefiltering and presentation decisions stay consistent.
struct NotificationServiceWakePolicySnapshot {
    let notifyMode: (String, String) -> ChatNotifyMode
    let mentionsBreakThroughMute: Bool
    let nickname: (String, String) -> String?
    let previewMode: NotificationPreviewMode

    @MainActor
    static func loadLive() -> Self {
        // One shared-defaults read per wake; per-record lookups hit the
        // in-memory snapshots. A nil mode snapshot means the shared suite
        // couldn't be resolved, so delivery fails safe (all suppressed);
        // the mention preference reads as off in that case too.
        let notifyModeSnapshot = ChatMuteStore.notifyModeSnapshot()
        let mentionsBreakThroughMute = MutedChatMentionsStore.mentionsBreakThroughMute()
        let muteEvaluationTime = Date.now
        let contactNicknames = ContactNicknameStore.nicknamesByKey()
        let previewMode = NotificationPreviewStore.mode()
        return Self(
            notifyMode: { accountIdHex, groupIdHex in
                ChatMuteStore.notifyMode(
                    accountIdHex: accountIdHex,
                    groupIdHex: groupIdHex,
                    snapshot: notifyModeSnapshot,
                    now: muteEvaluationTime
                )
            },
            mentionsBreakThroughMute: mentionsBreakThroughMute,
            nickname: { ownerAccountIdHex, contactAccountIdHex in
                ContactNicknameStore.nickname(
                    ownerAccountIdHex: ownerAccountIdHex,
                    contactAccountIdHex: contactAccountIdHex,
                    in: contactNicknames
                )
            },
            previewMode: previewMode
        )
    }
}

nonisolated struct NotificationServiceWakeEnvironment: Sendable {
    var makeRuntime: @MainActor @Sendable () throws -> any NotificationServiceWakeRuntime
    var auditLogSource: @MainActor @Sendable () -> AuditLogSourceFfi
    var loadPolicySnapshot: @MainActor @Sendable () -> NotificationServiceWakePolicySnapshot
    var maxWaitMs: UInt32
    var proactiveBudget: Duration
    var sleep: @Sendable (Duration) async throws -> Void
    var submitAdditionalPresentation: @MainActor @Sendable (LocalNotificationPresentation, _ applicationBadgeCount: Int?) -> Void

    static let live = Self(
        makeRuntime: { try LiveNotificationServiceWakeRuntime() },
        auditLogSource: { AuditLogSourceBuildConfig.current() },
        loadPolicySnapshot: { NotificationServiceWakePolicySnapshot.loadLive() },
        maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
        proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
        sleep: { duration in
            try await Task.sleep(for: duration)
        },
        submitAdditionalPresentation: { presentation, applicationBadgeCount in
            // A wake alerts once, through its primary. Caught-up records
            // and overflow summaries land quietly in Notification Center.
            // Submit via callback-based `add(_:withCompletionHandler:)`
            // synchronously on MainActor right after freezing the primary
            // snapshot and before closing storage so hard expiration cannot
            // complete the extension before these bounded requests are handed
            // to Notification Center.
            let content = NotificationCommunicationDecorator.decorated(
                NotificationContentDecorator.makeContent(
                    for: presentation,
                    applicationBadgeCount: applicationBadgeCount,
                    alerting: .quiet
                ),
                presentation: presentation,
                avatarData: nil
            )
            let request = UNNotificationRequest(
                identifier: presentation.identifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    )
}

/// Thread-safe box for transferring an unshared ObjC value across isolation
/// boundaries after synchronously copying it on the sender's thread.
// swiftlint:disable:next no_unchecked_sendable
nonisolated private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Thread-safe one-shot delivery gate shared between `UNNotificationServiceExtension`'s
/// arbitrary system callback threads (`didReceive` / `serviceExtensionTimeWillExpire`)
/// and the coordinator's `@MainActor` session work. Never holds its lock across
/// `contentHandler` invocation. Explicitly `nonisolated` under Swift 6.2 default
/// `@MainActor` isolation so background-thread calls never assert the main executor.
nonisolated private final class NotificationWakeDelivery: Sendable {
    /// Holds Apple's non-`Sendable` ObjC `UNNotificationContent` snapshots and
    /// `UNNotificationServiceExtension` completion closure. Exclusively accessed
    /// under `NotificationWakeDelivery.state`'s `Mutex`, and every stored content
    /// is synchronously copied as an immutable snapshot before locking.
    // swiftlint:disable:next no_unchecked_sendable
    private struct State: @unchecked Sendable {
        var handler: ((UNNotificationContent) -> Void)?
        let fallbackContent: UNNotificationContent
        var preparedContent: UNNotificationContent?
    }

    let id = UUID()
    let ownerID: UUID
    private let state: Mutex<State>

    init(
        ownerID: UUID,
        initialContent: UNNotificationContent,
        handler: @escaping (UNNotificationContent) -> Void
    ) {
        self.ownerID = ownerID
        // Snapshot an immutable fallback up front so hard expiration from any
        // thread delivers synchronously without touching mutable state.
        let fallback: UNNotificationContent
        if let mutable = initialContent.mutableCopy() as? UNMutableNotificationContent {
            NotificationContentDecorator.applyFallback(to: mutable)
            fallback = (mutable.copy() as? UNNotificationContent) ?? mutable
        } else {
            fallback = initialContent
        }
        state = Mutex(State(handler: handler, fallbackContent: fallback, preparedContent: nil))
    }

    var isPending: Bool {
        state.withLock { $0.handler != nil }
    }

    func setPreparedContent(_ content: UNNotificationContent) {
        let snapshot = (content.copy() as? UNNotificationContent) ?? content
        state.withLock { state in
            guard state.handler != nil else { return }
            state.preparedContent = snapshot
        }
    }

    /// Atomically claims the one-shot handler and invokes it synchronously on
    /// the caller's thread with the prepared snapshot (or fallback if none was
    /// prepared yet).
    @discardableResult
    func deliver() -> Bool {
        let claimed: (((UNNotificationContent) -> Void), UNNotificationContent)? =
            state.withLock { state in
                guard let handler = state.handler else { return nil }
                state.handler = nil
                let deliverable = state.preparedContent ?? state.fallbackContent
                state.preparedContent = nil
                return (handler, deliverable)
            }
        guard let (handler, deliverable) = claimed else { return false }
        handler(deliverable)
        return true
    }
}

/// Coordinates wakes delivered to `UNNotificationServiceExtension` instances in
/// the extension process.
///
/// Both `didReceive` and `serviceExtensionTimeWillExpire` are safe to call from
/// any thread (matching Apple's `UNNotificationServiceExtension` contract).
/// Each wake owns a thread-safe `NotificationWakeDelivery` so hard expiration
/// claims the handler and delivers the best prepared immutable snapshot
/// synchronously on the calling thread while scheduling `@MainActor` runtime
/// teardown. Consecutive wakes serialize runtime construction behind a single
/// coordinator-owned storage-close barrier for the most recent runtime that
/// actually opened.
nonisolated final class NotificationServiceWakeCoordinator: Sendable {
    private struct PendingStart: Sendable {
        let content: UncheckedSendableBox<UNMutableNotificationContent>
        let delivery: NotificationWakeDelivery
    }

    private struct QueueState: Sendable {
        var pendingDeliveries: [NotificationWakeDelivery] = []
        var pendingStarts: [PendingStart] = []
        var drainScheduled = false
    }

    private let queue = Mutex<QueueState>(QueueState())
    private let state: NotificationServiceWakeCoordinatorState

    init(environment: NotificationServiceWakeEnvironment) {
        state = NotificationServiceWakeCoordinatorState(environment: environment)
    }

    func didReceive(
        _ request: UNNotificationRequest,
        ownerID: UUID,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let delivery = NotificationWakeDelivery(
            ownerID: ownerID,
            initialContent: request.content,
            handler: contentHandler
        )
        let mutableContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        let pendingStart = PendingStart(
            content: UncheckedSendableBox(value: mutableContent),
            delivery: delivery
        )
        // Record registration and enqueue session start atomically under the
        // same lock, then drive a single MainActor drain in FIFO registration
        // order so an earlier wake delayed on another thread can never overtake
        // and replace a newer wake.
        let shouldScheduleDrain = queue.withLock { queueState -> Bool in
            queueState.pendingDeliveries.removeAll { !$0.isPending }
            queueState.pendingDeliveries.append(delivery)
            queueState.pendingStarts.append(pendingStart)
            guard !queueState.drainScheduled else { return false }
            queueState.drainScheduled = true
            return true
        }
        guard shouldScheduleDrain else { return }
        Task { @MainActor [self] in
            self.drainPendingStartsOnMainActor()
        }
    }

    @MainActor
    private func drainPendingStartsOnMainActor() {
        while true {
            let batch = queue.withLock { queueState -> [PendingStart] in
                if queueState.pendingStarts.isEmpty {
                    queueState.drainScheduled = false
                    return []
                }
                let items = queueState.pendingStarts
                queueState.pendingStarts.removeAll(keepingCapacity: true)
                return items
            }
            guard !batch.isEmpty else { return }
            for item in batch {
                state.startSession(
                    content: item.content.value,
                    delivery: item.delivery
                )
            }
        }
    }

    func serviceExtensionTimeWillExpire(ownerID: UUID) {
        // Atomically claim and deliver synchronously on whatever thread iOS
        // invokes `serviceExtensionTimeWillExpire()` on — never hop to
        // MainActor before calling `contentHandler`. Scope the asynchronous
        // MainActor cleanup to the exact delivery IDs claimed here so a fresh
        // wake starting on a reused extension instance before MainActor drains
        // is never cancelled by an earlier wake's expiration.
        let matching = queue.withLock { queueState -> [NotificationWakeDelivery] in
            let claimed = queueState.pendingDeliveries.filter { $0.ownerID == ownerID && $0.isPending }
            queueState.pendingDeliveries.removeAll { $0.ownerID == ownerID || !$0.isPending }
            return claimed
        }
        let expiredDeliveryIDs = Set(matching.map(\.id))
        for delivery in matching {
            delivery.deliver()
        }
        guard !expiredDeliveryIDs.isEmpty else { return }
        Task { @MainActor [state] in
            state.expireSessions(deliveryIDs: expiredDeliveryIDs)
        }
    }
}

@MainActor
private final class NotificationServiceWakeCoordinatorState: Sendable {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    private let environment: NotificationServiceWakeEnvironment
    private var activeSession: NotificationServiceWakeSession?
    private var sessions: [NotificationServiceWakeSession] = []
    /// Single coordinator-owned close barrier for the most recent session that
    /// actually opened a runtime. Waiting wakes that expire before opening
    /// storage never replace this barrier, so later wakes still wait for the
    /// open runtime to finish closing.
    private var activeRuntimeBarrier: Task<Void, Never>?

    nonisolated init(environment: NotificationServiceWakeEnvironment) {
        self.environment = environment
    }

    func startSession(
        content: UNMutableNotificationContent,
        delivery: NotificationWakeDelivery
    ) {
        sessions.removeAll { !$0.isRetainedInCoordinator }
        // Hard expiration may already have claimed and delivered this wake on
        // a background thread before this MainActor task ran.
        guard delivery.isPending else { return }

        if let previousSession = activeSession {
            previousSession.cancelForReplacement()
        }

        let priorRuntimeBarrier = activeRuntimeBarrier
        let session = NotificationServiceWakeSession(
            content: content,
            delivery: delivery,
            environment: environment
        ) { [weak self] barrier in
            self?.activeRuntimeBarrier = barrier
        }
        activeSession = session
        sessions.append(session)
        session.start(afterDrainingPriorRuntime: priorRuntimeBarrier)
    }

    func expireSessions(deliveryIDs: Set<UUID>) {
        for session in sessions where deliveryIDs.contains(session.deliveryID) {
            session.handleHardExpiration()
        }
        sessions.removeAll { !$0.isRetainedInCoordinator }
    }
}

@MainActor
private final class NotificationServiceWakeSession {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    private let delivery: NotificationWakeDelivery
    private let environment: NotificationServiceWakeEnvironment
    private let onRuntimeOpened: @MainActor (Task<Void, Never>) -> Void
    private let wakeStartedAt = ContinuousClock.now
    private var bestAttemptContent: UNMutableNotificationContent?
    private var collectionTask: Task<Void, Never>?
    private var expirationWatchdogTask: Task<Void, Never>?
    private var activeRuntime: (any NotificationServiceWakeRuntime)?
    private var runtimeShutdownTask: Task<Void, Never>?
    /// Single storage-close barrier for successor wakes. Resolves once this
    /// session's opened runtime finishes `shutdownAndClose()`.
    private var runtimeReleased = false
    private var runtimeReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var collectionInFlight = false
    private var proactiveBudgetElapsed = false
    private var replacementRequested = false
    private var preparedDiagnosticOutcome: NotificationServiceDiagnosticOutcome?
    private var preparedNotificationCount = 0
    private let diagnosticStartedAt = Date()
    private var diagnosticStage: NotificationServiceDiagnosticStage = .received
    private var didRecordDiagnostic = false
    private var expirationInProgress = false

    private static let diagnosticLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios.NotificationService",
        category: "notification-service"
    )

    init(
        content: UNMutableNotificationContent,
        delivery: NotificationWakeDelivery,
        environment: NotificationServiceWakeEnvironment,
        onRuntimeOpened: @escaping @MainActor (Task<Void, Never>) -> Void
    ) {
        self.bestAttemptContent = content
        self.delivery = delivery
        self.environment = environment
        self.onRuntimeOpened = onRuntimeOpened
    }

    var deliveryID: UUID {
        delivery.id
    }

    /// Kept in the coordinator until MainActor `finish()` runs, so a hard
    /// expiration that already claimed `delivery` on a background thread still
    /// locates this session for runtime cleanup even if a successor wake starts
    /// first.
    var isRetainedInCoordinator: Bool {
        bestAttemptContent != nil
    }

    func start(afterDrainingPriorRuntime priorRuntimeDrain: Task<Void, Never>?) {
        collectionTask = Task {
            await self.collectAndDecorateNotification(priorRuntimeDrain: priorRuntimeDrain)
        }
        let sleep = environment.sleep
        let proactiveBudget = environment.proactiveBudget
        expirationWatchdogTask = Task { [weak self] in
            try? await sleep(proactiveBudget)
            guard !Task.isCancelled else { return }
            self?.handleProactiveWatchdogExpiration()
        }
    }

    private func handleProactiveWatchdogExpiration() {
        guard bestAttemptContent != nil, !expirationInProgress else { return }
        proactiveBudgetElapsed = true
        if collectionInFlight {
            // Once `collectNotificationsAfterWake` has started, MDK may already
            // have advanced the background notification cursor. Let collection
            // and mandatory privacy checks finish, skip the optional badge
            // scan, freeze primary + submit extras, and close storage promptly;
            // iOS's hard expiry remains the cutoff.
            return
        }
        beginExpirationCleanup(outcome: .expired)
    }

    /// Transitions this session out because a newer wake arrived. Once
    /// `collectNotificationsAfterWake` has started, MDK may already have
    /// drained notifications from the background cursor, so ordinary
    /// replacement preserves the consumed batch (skipping the optional badge
    /// scan and letting the existing task close storage and deliver).
    func cancelForReplacement() {
        guard bestAttemptContent != nil, !expirationInProgress else { return }
        if !delivery.isPending {
            // Hard expiration already claimed and delivered this wake on a
            // background thread before `expireSessions(deliveryIDs:)` drained.
            handleHardExpiration()
            return
        }
        replacementRequested = true
        if collectionInFlight {
            return
        }
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        beginExpirationCleanup(outcome: .replaced)
    }

    /// MainActor cleanup after `NotificationServiceWakeCoordinator` already
    /// delivered the best prepared snapshot synchronously on the expiration
    /// thread: cancel remaining work and begin/retain runtime shutdown.
    func handleHardExpiration() {
        guard !expirationInProgress else { return }
        expirationInProgress = true
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        recordDiagnostic(
            outcome: preparedDiagnosticOutcome ?? .expired,
            notificationCount: preparedNotificationCount
        )
        collectionTask?.cancel()
        _ = beginRuntimeShutdown()
        finish()
    }

    private func beginExpirationCleanup(outcome: NotificationServiceDiagnosticOutcome) {
        guard bestAttemptContent != nil, !expirationInProgress else { return }
        expirationInProgress = true
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        recordDiagnostic(outcome: outcome)
        collectionTask?.cancel()
        let shutdownTask = beginRuntimeShutdown()
        Task {
            await shutdownTask?.value
            self.finish()
        }
    }

    private func collectAndDecorateNotification(
        priorRuntimeDrain: Task<Void, Never>?
    ) async {
        defer {
            if activeRuntime != nil {
                _ = beginRuntimeShutdown()
            }
            if runtimeShutdownTask == nil {
                markRuntimeReleased()
            }
        }
        guard let content = bestAttemptContent, delivery.isPending else {
            finish()
            return
        }

        await priorRuntimeDrain?.value
        if Task.isCancelled || expirationInProgress || !delivery.isPending {
            finish()
            return
        }

        do {
            let runtime = try environment.makeRuntime()
            activeRuntime = runtime
            onRuntimeOpened(runtimeReleaseBarrierTask())
            // Before `start()` opens accounts, whose recorders keep the source they open with.
            _ = try? runtime.setAuditLogSource(source: environment.auditLogSource())
            diagnosticStage = .runtimeCreated
            if Task.isCancelled || expirationInProgress || !delivery.isPending {
                await beginRuntimeShutdown(expected: runtime)?.value
                finish()
                return
            }
            do {
                try await runtime.start()
                diagnosticStage = .runtimeStarted
                guard await continueCollection(using: runtime) else { return }
                collectionInFlight = true
                let effectiveMaxWaitMs = NotificationServiceTimeoutPolicy.effectiveCollectionWaitMs(
                    configuredMaxWaitMs: environment.maxWaitMs,
                    proactiveBudget: environment.proactiveBudget,
                    elapsed: wakeStartedAt.duration(to: ContinuousClock.now)
                )
                let result = try await runtime.collectNotificationsAfterWake(
                    maxWaitMs: effectiveMaxWaitMs,
                    source: .apnsNse
                )
                diagnosticStage = .collectionCompleted
                guard await continueCollection(using: runtime) else { return }
                let policy = environment.loadPolicySnapshot()
                let accountRefs = Set(result.notifications.map(\.accountRef))
                let enabledByAccountRef = await runtime.localNotificationsEnabled(
                    accountRefs: accountRefs
                )
                guard await continueCollection(using: runtime) else { return }
                let localNotificationsEnabled: (String) -> Bool = { accountRef in
                    enabledByAccountRef[accountRef] ?? true
                }
                let accountsRequiringArchivedLookup =
                    NotificationPresentationPolicy.accountRefsRequiringArchivedLookup(
                        for: result,
                        localNotificationsEnabled: localNotificationsEnabled,
                        notifyMode: policy.notifyMode,
                        mentionsBreakThroughMute: policy.mentionsBreakThroughMute
                    )
                let archivedChatKeys = await runtime.archivedChatKeys(
                    accountRefs: accountsRequiringArchivedLookup
                )
                guard await continueCollection(using: runtime) else { return }
                // Refresh the SpringBoard badge count only while ample
                // proactive budget margin remains and no successor wake is
                // waiting, so the synchronous aggregate unread scan does not
                // start near the deadline and crowd terminal storage closure.
                let remainingProactiveBudget = environment.proactiveBudget
                    - wakeStartedAt.duration(to: ContinuousClock.now)
                var applicationBadgeCount: Int?
                if result.status != .failed,
                   !proactiveBudgetElapsed,
                   !replacementRequested,
                   remainingProactiveBudget >= NotificationServiceTimeoutPolicy.minimumBadgeScanRemainingBudget {
                    let count = await runtime.applicationBadgeCount()
                    guard await continueCollection(using: runtime) else { return }
                    applicationBadgeCount = count
                }
                let decision = NotificationServiceProjection.decision(
                    for: result,
                    localNotificationsEnabled: localNotificationsEnabled,
                    isArchived: { accountRef, groupIdHex in
                        archivedChatKeys.contains(
                            NotificationServiceProjection.archivedChatKey(
                                accountRef: accountRef,
                                groupIdHex: groupIdHex
                            )
                        )
                    },
                    notifyMode: policy.notifyMode,
                    mentionsBreakThroughMute: policy.mentionsBreakThroughMute,
                    nickname: policy.nickname,
                    previewMode: policy.previewMode
                )
                // An empty wake can't be attributed: the engine drops
                // disabled accounts' records at ingest, so `.noData` is
                // ambiguous between "nothing existed" and "records were
                // suppressed". Account-wide inference gets both directions
                // wrong, so the fallback stays audible until the engine
                // reports suppressed records explicitly.
                //
                // Freeze the immutable primary snapshot to the delivery gate,
                // then hand off bounded extras synchronously BEFORE closing
                // storage, so neither a stalled shutdown nor hard expiration
                // can drop already-projected notifications.
                publishPreparedPresentations(
                    for: decision,
                    result: result,
                    in: content,
                    applicationBadgeCount: applicationBadgeCount
                )
                await beginRuntimeShutdown(expected: runtime)?.value
                if result.status != .failed {
                    diagnosticStage = .rendered
                }
                recordDiagnostic(
                    outcome: preparedDiagnosticOutcome ?? .failed,
                    notificationCount: preparedNotificationCount
                )
            } catch {
                recordDiagnostic(outcome: .failed)
                await beginRuntimeShutdown(expected: runtime)?.value
            }
        } catch let error as MarmotKitError where error.isRuntimeOwnershipContention {
            recordDiagnostic(outcome: .runtimeOwnershipContention)
            finish()
            return
        } catch {
            // Keep the provider payload generic when collection fails. The main
            // app will catch up when it next starts or receives a local event.
            recordDiagnostic(outcome: .failed)
        }

        finish()
    }

    private func continueCollection(using runtime: any NotificationServiceWakeRuntime) async -> Bool {
        guard activeRuntime === runtime, !Task.isCancelled, !expirationInProgress, delivery.isPending else {
            await beginRuntimeShutdown(expected: runtime)?.value
            return false
        }
        return true
    }

    private func beginRuntimeShutdown(
        expected: (any NotificationServiceWakeRuntime)? = nil
    ) -> Task<Void, Never>? {
        if let existing = runtimeShutdownTask {
            return existing
        }
        guard let runtime = takeActiveRuntimeForShutdown(expected) else {
            return nil
        }
        let task = Task { @MainActor in
            _ = try? await runtime.shutdownAndClose()
            self.markRuntimeReleased()
        }
        runtimeShutdownTask = task
        return task
    }

    private func runtimeReleaseBarrierTask() -> Task<Void, Never> {
        Task { @MainActor in
            await self.waitForRuntimeRelease()
        }
    }

    private func waitForRuntimeRelease() async {
        guard !runtimeReleased else { return }
        await withCheckedContinuation { continuation in
            if runtimeReleased {
                continuation.resume()
            } else {
                runtimeReleaseWaiters.append(continuation)
            }
        }
    }

    private func markRuntimeReleased() {
        guard !runtimeReleased else { return }
        runtimeReleased = true
        let waiters = runtimeReleaseWaiters
        runtimeReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func takeActiveRuntimeForShutdown(
        _ expected: (any NotificationServiceWakeRuntime)? = nil
    ) -> (any NotificationServiceWakeRuntime)? {
        guard let active = activeRuntime else { return nil }
        if let expected, active !== expected { return nil }
        activeRuntime = nil
        return active
    }

    private func recordDiagnostic(
        outcome: NotificationServiceDiagnosticOutcome,
        notificationCount: Int = 0
    ) {
        guard !didRecordDiagnostic else { return }
        didRecordDiagnostic = true
        let elapsed = max(0, Date().timeIntervalSince(diagnosticStartedAt))
        let durationMilliseconds = Int((elapsed * 1_000).rounded())
        Self.diagnosticLog.info(
            "wake_finished outcome=\(outcome.rawValue, privacy: .public) stage=\(self.diagnosticStage.rawValue, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) notification_count=\(notificationCount, privacy: .public)"
        )
    }

    private func publishPreparedPresentations(
        for decision: NotificationServiceRenderDecision,
        result: BackgroundNotificationCollectionFfi,
        in content: UNMutableNotificationContent,
        applicationBadgeCount: Int?
    ) {
        preparedDiagnosticOutcome = result.status == .failed ? .failed : decision.diagnosticOutcome
        preparedNotificationCount = result.notifications.count
        if let applicationBadgeCount {
            NotificationContentDecorator.applyApplicationBadgeCount(applicationBadgeCount, to: content)
        }
        switch decision {
        case .decorate(let presentation, let additionalPresentations):
            NotificationContentDecorator.apply(presentation, to: content)
            let decorated = NotificationCommunicationDecorator.decorated(
                content,
                presentation: presentation,
                avatarData: nil
            )
            // Freeze the filtered primary snapshot BEFORE handing off bounded
            // extras so a background hard-expiry interrupting the submission
            // loop still delivers the prepared primary instead of fallback.
            delivery.setPreparedContent(decorated)
            for extra in additionalPresentations {
                environment.submitAdditionalPresentation(extra, applicationBadgeCount)
            }
        case .deliverQuietly:
            NotificationContentDecorator.applyQuietDelivery(to: content)
            delivery.setPreparedContent(content)
        case .fallback:
            NotificationContentDecorator.applyFallback(to: content)
            delivery.setPreparedContent(content)
        }
    }

    private func finish() {
        guard bestAttemptContent != nil else { return }
        bestAttemptContent = nil
        collectionTask = nil
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        delivery.deliver()
    }
}
