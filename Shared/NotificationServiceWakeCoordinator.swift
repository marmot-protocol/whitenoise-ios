import Foundation
import MarmotKit
import OSLog
import Synchronization
import UserNotifications

/// Minimal runtime surface owned by one Notification Service Extension wake.
/// `LiveNotificationServiceWakeRuntime` wraps `Marmot` in production; unit tests
/// inject a fake to verify per-wake isolation and shutdown ordering.
protocol NotificationServiceWakeRuntime: AnyObject, Sendable {
    func setAuditLogSource(source: AuditLogSourceFfi) throws
    func start() async throws
    func collectNotificationsAfterWake(
        maxWaitMs: UInt32,
        source: NotificationWakeSourceFfi
    ) async throws -> BackgroundNotificationCollectionFfi
    func localNotificationsEnabled(accountRefs: Set<String>) async -> [String: Bool]
    func archivedChatKeys(accountRefs: Set<String>) async -> Set<String>
    func shutdownAndClose() async throws
}

final class LiveNotificationServiceWakeRuntime: NotificationServiceWakeRuntime {
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
        try marmot.setAuditLogSource(source: source)
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

struct NotificationServiceWakeEnvironment: Sendable {
    var makeRuntime: @MainActor () throws -> any NotificationServiceWakeRuntime
    var auditLogSource: @MainActor () -> AuditLogSourceFfi
    var loadPolicySnapshot: @MainActor () -> NotificationServiceWakePolicySnapshot
    var maxWaitMs: UInt32
    var proactiveBudget: Duration
    var sleep: @Sendable (Duration) async throws -> Void
    var enqueueAdditionalPresentation: @Sendable (LocalNotificationPresentation) async -> Void

    static let live = Self(
        makeRuntime: { try LiveNotificationServiceWakeRuntime() },
        auditLogSource: { AuditLogSourceBuildConfig.current() },
        loadPolicySnapshot: { NotificationServiceWakePolicySnapshot.loadLive() },
        maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
        proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
        sleep: { duration in
            try await Task.sleep(for: duration)
        },
        enqueueAdditionalPresentation: { presentation in
            // A wake alerts once, through its primary. Caught-up records
            // and overflow summaries land quietly in Notification Center.
            let content = NotificationCommunicationDecorator.decorated(
                NotificationContentDecorator.makeContent(
                    for: presentation,
                    applicationBadgeCount: nil,
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
            try? await UNUserNotificationCenter.current().add(request)
        }
    )
}

/// Thread-safe box for transferring an unshared ObjC value across isolation
/// boundaries after synchronously copying it on the sender's thread.
// swiftlint:disable:next no_unchecked_sendable
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Thread-safe one-shot delivery gate shared between `UNNotificationServiceExtension`'s
/// arbitrary system callback threads (`didReceive` / `serviceExtensionTimeWillExpire`)
/// and the coordinator's `@MainActor` session work. Never holds its lock across
/// `contentHandler` invocation.
private final class NotificationWakeDelivery: Sendable {
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
final class NotificationServiceWakeCoordinator: Sendable {
    private let pendingDeliveries = Mutex<[NotificationWakeDelivery]>([])
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
        pendingDeliveries.withLock { deliveries in
            deliveries.removeAll { !$0.isPending }
            deliveries.append(delivery)
        }
        let mutableContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        let contentBox = UncheckedSendableBox(value: mutableContent)
        Task { @MainActor [state] in
            state.startSession(
                content: contentBox.value,
                ownerID: ownerID,
                delivery: delivery
            )
        }
    }

    func serviceExtensionTimeWillExpire(ownerID: UUID) {
        // Atomically claim and deliver synchronously on whatever thread iOS
        // invokes `serviceExtensionTimeWillExpire()` on — never hop to
        // MainActor before calling `contentHandler`.
        let matching = pendingDeliveries.withLock { deliveries -> [NotificationWakeDelivery] in
            let claimed = deliveries.filter { $0.ownerID == ownerID && $0.isPending }
            deliveries.removeAll { $0.ownerID == ownerID || !$0.isPending }
            return claimed
        }
        for delivery in matching {
            delivery.deliver()
        }
        Task { @MainActor [state] in
            state.expireSessions(ownerID: ownerID)
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
        ownerID: UUID,
        delivery: NotificationWakeDelivery
    ) {
        sessions.removeAll { !$0.isAwaitingDelivery }
        // Hard expiration may already have claimed and delivered this wake on
        // a background thread before this MainActor task ran.
        guard delivery.isPending else { return }

        if let previousSession = activeSession {
            previousSession.cancelForReplacement()
        }

        let priorRuntimeBarrier = activeRuntimeBarrier
        let session = NotificationServiceWakeSession(
            ownerID: ownerID,
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

    func expireSessions(ownerID: UUID) {
        for session in sessions where session.ownerID == ownerID {
            session.handleHardExpiration()
        }
        sessions.removeAll { !$0.isAwaitingDelivery }
    }
}

@MainActor
private final class NotificationServiceWakeSession {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    let ownerID: UUID
    private let delivery: NotificationWakeDelivery
    private let environment: NotificationServiceWakeEnvironment
    private let onRuntimeOpened: @MainActor (Task<Void, Never>) -> Void
    private let wakeStartedAt = ContinuousClock.now
    private var bestAttemptContent: UNMutableNotificationContent?
    private var collectionTask: Task<Void, Never>?
    private var expirationWatchdogTask: Task<Void, Never>?
    private var expirationCleanupTask: Task<Void, Never>?
    private var activeRuntime: (any NotificationServiceWakeRuntime)?
    private var runtimeShutdownTask: Task<Void, Never>?
    /// Single storage-close barrier for successor wakes. Resolves once this
    /// session's opened runtime finishes `shutdownAndClose()`, decoupled from
    /// post-projection Notification Center enqueues.
    private var runtimeReleased = false
    private var runtimeReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var collectionInFlight = false
    private var skipEnqueueWait = false
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
        ownerID: UUID,
        content: UNMutableNotificationContent,
        delivery: NotificationWakeDelivery,
        environment: NotificationServiceWakeEnvironment,
        onRuntimeOpened: @escaping @MainActor (Task<Void, Never>) -> Void
    ) {
        self.ownerID = ownerID
        self.bestAttemptContent = content
        self.delivery = delivery
        self.environment = environment
        self.onRuntimeOpened = onRuntimeOpened
    }

    var isAwaitingDelivery: Bool {
        bestAttemptContent != nil && delivery.isPending
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
        if preparedDiagnosticOutcome != nil {
            // Primary content is already prepared and bounded extras are
            // already submitted to Notification Center. Close storage if still
            // open and deliver the prepared primary immediately once storage
            // closes, rather than stalling behind slow Notification Center
            // completions.
            completePreparedPrimaryAfterShutdown()
            return
        }
        if collectionInFlight {
            // Once `collectNotificationsAfterWake` has started, MDK may already
            // have advanced the background notification cursor. Let collection
            // and mandatory privacy checks finish, then deliver without waiting
            // on slow enqueue completions; iOS's hard expiry remains the cutoff.
            skipEnqueueWait = true
            return
        }
        beginExpirationCleanup(outcome: .expired)
    }

    /// Transitions this session out because a newer wake arrived. Once
    /// `collectNotificationsAfterWake` has started, MDK may already have
    /// drained notifications from the background cursor, so ordinary
    /// replacement preserves the consumed batch (releasing a prepared primary
    /// promptly once storage closes instead of waiting for the watchdog).
    func cancelForReplacement() {
        guard bestAttemptContent != nil, !expirationInProgress else { return }
        if preparedDiagnosticOutcome != nil {
            completePreparedPrimaryAfterShutdown()
            return
        }
        if collectionInFlight {
            skipEnqueueWait = true
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

    private func completePreparedPrimaryAfterShutdown() {
        guard !expirationInProgress else { return }
        expirationInProgress = true
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        collectionTask?.cancel()
        let shutdownTask = beginRuntimeShutdown()
        let outcome = preparedDiagnosticOutcome ?? .fallback
        let notificationCount = preparedNotificationCount
        expirationCleanupTask = Task {
            await shutdownTask?.value
            self.recordDiagnostic(outcome: outcome, notificationCount: notificationCount)
            self.finish()
        }
    }

    private func beginExpirationCleanup(outcome: NotificationServiceDiagnosticOutcome) {
        guard bestAttemptContent != nil, !expirationInProgress else { return }
        expirationInProgress = true
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        recordDiagnostic(outcome: outcome)
        collectionTask?.cancel()
        let shutdownTask = beginRuntimeShutdown()
        expirationCleanupTask = Task {
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
                // Publish an immutable primary snapshot to the thread-safe
                // delivery gate AND submit the bounded additional presentations
                // concurrently BEFORE closing storage, so neither a stalled
                // shutdown nor hard expiration can drop already-projected
                // notifications (and no fresh aggregate SQLite badge scan sits
                // on the deadline-sensitive path).
                let additionalPresentations = preparePrimaryContent(
                    for: decision,
                    result: result,
                    in: content
                )
                let enqueueTasks = submitAdditionalPresentations(additionalPresentations)
                await beginRuntimeShutdown(expected: runtime)?.value
                // Wait for the already-submitted additional requests while
                // within the proactive budget and unreplaced; proactive
                // watchdog or late replacement releases primary delivery once
                // storage is closed without cancelling the in-flight submissions.
                if !enqueueTasks.isEmpty, !skipEnqueueWait, !Task.isCancelled, !expirationInProgress {
                    for task in enqueueTasks {
                        await task.value
                        if skipEnqueueWait || Task.isCancelled || expirationInProgress { break }
                    }
                }
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

    private func preparePrimaryContent(
        for decision: NotificationServiceRenderDecision,
        result: BackgroundNotificationCollectionFfi,
        in content: UNMutableNotificationContent
    ) -> [LocalNotificationPresentation] {
        preparedDiagnosticOutcome = result.status == .failed ? .failed : decision.diagnosticOutcome
        preparedNotificationCount = result.notifications.count
        switch decision {
        case .decorate(let presentation, let additionalPresentations):
            NotificationContentDecorator.apply(presentation, to: content)
            let decorated = NotificationCommunicationDecorator.decorated(
                content,
                presentation: presentation,
                avatarData: nil
            )
            delivery.setPreparedContent(decorated)
            return additionalPresentations
        case .deliverQuietly:
            NotificationContentDecorator.applyQuietDelivery(to: content)
            delivery.setPreparedContent(content)
            return []
        case .fallback:
            NotificationContentDecorator.applyFallback(to: content)
            delivery.setPreparedContent(content)
            return []
        }
    }

    private func submitAdditionalPresentations(
        _ presentations: [LocalNotificationPresentation]
    ) -> [Task<Void, Never>] {
        guard !presentations.isEmpty else { return [] }
        let enqueue = environment.enqueueAdditionalPresentation
        return presentations.map { presentation in
            Task {
                await enqueue(presentation)
            }
        }
    }

    private func finish() {
        guard bestAttemptContent != nil else { return }
        bestAttemptContent = nil
        collectionTask = nil
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        expirationCleanupTask = nil
        delivery.deliver()
    }
}
