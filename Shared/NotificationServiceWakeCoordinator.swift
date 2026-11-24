import Foundation
import MarmotKit
import OSLog
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
    func applicationBadgeCount() async -> Int?
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

struct NotificationServiceWakeEnvironment {
    var makeRuntime: @MainActor () throws -> any NotificationServiceWakeRuntime
    var auditLogSource: @MainActor () -> AuditLogSourceFfi
    var loadPolicySnapshot: @MainActor () -> NotificationServiceWakePolicySnapshot
    var maxWaitMs: UInt32
    var proactiveBudget: Duration
    var watchdogSleep: @Sendable () async throws -> Void
    var enqueueAdditionalPresentation: @Sendable (
        LocalNotificationPresentation,
        Int?
    ) async -> Void

    static let live = Self(
        makeRuntime: { try LiveNotificationServiceWakeRuntime() },
        auditLogSource: { AuditLogSourceBuildConfig.current() },
        loadPolicySnapshot: { NotificationServiceWakePolicySnapshot.loadLive() },
        maxWaitMs: NotificationServiceProjection.maxWakeWaitMs,
        proactiveBudget: NotificationServiceTimeoutPolicy.proactiveExpirationDelay,
        watchdogSleep: {
            try await Task.sleep(for: NotificationServiceTimeoutPolicy.proactiveExpirationDelay)
        },
        enqueueAdditionalPresentation: { presentation, applicationBadgeCount in
            // A wake alerts once, through its primary. Caught-up records
            // and overflow summaries land quietly in Notification Center.
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
            try? await UNUserNotificationCenter.current().add(request)
        }
    )
}

/// Coordinates wakes delivered to `UNNotificationServiceExtension` instances in
/// the extension process.
///
/// iOS can reuse one `NotificationService` instance across consecutive pushes or
/// construct distinct instances in the same process. Each `didReceive` gets an
/// isolated `NotificationServiceWakeSession` tagged with its owning extension
/// `ownerID`, owning its own `OneShotNotificationDelivery`, tasks, and runtime
/// handle. A new wake cancels any prior pre-collection session immediately, or
/// lets a session already inside/after `collectNotificationsAfterWake` finish
/// delivering its consumed notifications (skipping optional badge reads, still
/// bounded by watchdog/expiration), and always drains the prior runtime shutdown
/// before opening a fresh `Marmot` instance. `serviceExtensionTimeWillExpire(ownerID:)`
/// expires only sessions belonging to that extension instance, delivering the
/// best prepared primary synchronously while keeping the shutdown barrier for
/// subsequent wakes.
@MainActor
final class NotificationServiceWakeCoordinator {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    private let environment: NotificationServiceWakeEnvironment
    private var activeSession: NotificationServiceWakeSession?
    private var drainingSessions: [UUID: NotificationServiceWakeSession] = [:]
    private var pendingRuntimeDrain: Task<Void, Never>?
    private var pendingRuntimeDrainID = UUID()

    init(environment: NotificationServiceWakeEnvironment) {
        self.environment = environment
    }

    func didReceive(
        _ request: UNNotificationRequest,
        ownerID: UUID,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let previousDrain = pendingRuntimeDrain
        let priorSessionDrain: Task<Void, Never>?
        if let previousSession = activeSession {
            priorSessionDrain = previousSession.cancelForReplacement()
            if previousSession.isAwaitingDelivery {
                let drainingID = UUID()
                drainingSessions[drainingID] = previousSession
                previousSession.onDelivered { [weak self] in
                    self?.drainingSessions.removeValue(forKey: drainingID)
                }
            }
        } else {
            priorSessionDrain = nil
        }

        let combinedPriorDrain: Task<Void, Never>?
        if previousDrain == nil, priorSessionDrain == nil {
            combinedPriorDrain = nil
        } else {
            let drainID = UUID()
            pendingRuntimeDrainID = drainID
            let combined = Task { @MainActor [weak self] in
                await previousDrain?.value
                await priorSessionDrain?.value
                if self?.pendingRuntimeDrainID == drainID {
                    self?.pendingRuntimeDrain = nil
                }
            }
            pendingRuntimeDrain = combined
            combinedPriorDrain = combined
        }

        let session = NotificationServiceWakeSession(
            ownerID: ownerID,
            request: request,
            contentHandler: contentHandler,
            environment: environment
        )
        activeSession = session
        session.start(afterDrainingPriorRuntime: combinedPriorDrain)
    }

    func serviceExtensionTimeWillExpire(ownerID: UUID) {
        for session in drainingSessions.values where session.ownerID == ownerID {
            session.beginExpirationCleanup(deliverImmediately: true)
        }
        if let activeSession, activeSession.ownerID == ownerID {
            activeSession.beginExpirationCleanup(deliverImmediately: true)
        }
    }
}

@MainActor
private final class NotificationServiceWakeSession {
    // Avoid the task-local isolated-deinit crash on iOS 26.2 and older.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    let ownerID: UUID
    private let delivery = OneShotNotificationDelivery()
    private let environment: NotificationServiceWakeEnvironment
    private let wakeStartedAt = ContinuousClock.now
    private var bestAttemptContent: UNMutableNotificationContent?
    /// Communication-intent copy of the primary content. `updating(from:)`
    /// returns a new immutable content, so it rides in its own slot and
    /// `finish` prefers it unless the timeout fallback rewrote the original.
    private var decoratedContent: UNNotificationContent?
    private var collectionTask: Task<Void, Never>?
    private var expirationWatchdogTask: Task<Void, Never>?
    private var expirationCleanupTask: Task<Void, Never>?
    private var additionalPresentationTask: Task<Void, Never>?
    private var activeRuntime: (any NotificationServiceWakeRuntime)?
    private var runtimeShutdownTask: Task<Void, Never>?
    /// Single storage-close barrier for successor wakes. Resolves once this
    /// session either exited without opening a runtime or finished
    /// `shutdownAndClose()`, decoupled from post-shutdown Notification Center
    /// enqueues.
    private var runtimeReleased = false
    private var runtimeReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var optionalBadgeContinuation: CheckedContinuation<Int?, Never>?
    private var onDeliveredHandler: (@MainActor () -> Void)?
    private var collectionInFlight = false
    private var replacedDuringOrAfterCollection = false
    private var skipOptionalPostCollectionWork = false
    private var applicationBadgeCount: Int?
    private var didApplyRenderDecision = false
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
        request: UNNotificationRequest,
        contentHandler: @escaping (UNNotificationContent) -> Void,
        environment: NotificationServiceWakeEnvironment
    ) {
        self.ownerID = ownerID
        self.environment = environment
        delivery.reset(handler: contentHandler)
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
    }

    var isAwaitingDelivery: Bool { bestAttemptContent != nil }

    func onDelivered(_ handler: @escaping @MainActor () -> Void) {
        if !isAwaitingDelivery {
            handler()
        } else {
            onDeliveredHandler = handler
        }
    }

    func start(afterDrainingPriorRuntime priorRuntimeDrain: Task<Void, Never>?) {
        collectionTask = Task {
            await self.collectAndDecorateNotification(priorRuntimeDrain: priorRuntimeDrain)
        }
        let watchdogSleep = environment.watchdogSleep
        expirationWatchdogTask = Task { [weak self] in
            try? await watchdogSleep()
            guard !Task.isCancelled else { return }
            self?.handleProactiveWatchdogExpiration()
        }
    }

    private func handleProactiveWatchdogExpiration() {
        guard bestAttemptContent != nil, !expirationInProgress else { return }
        if collectionInFlight {
            // Once `collectNotificationsAfterWake` has started, MDK may already
            // have advanced the background notification cursor. Skip or abort
            // optional badge work so privacy checks, projection, and delivery
            // finish promptly instead of discarding a consumed batch to a
            // fallback; iOS's `serviceExtensionTimeWillExpire()` remains the
            // hard cutoff.
            skipOptionalPostCollectionWork = true
            abortOptionalBadgeRead()
            return
        }
        beginExpirationCleanup(deliverImmediately: false)
    }

    /// Transitions this session out because a newer wake arrived, and returns a
    /// barrier task that resolves once this session has released its runtime
    /// lock. Once `collectNotificationsAfterWake` has started, MDK may already
    /// have drained notifications from the background cursor, so ordinary
    /// replacement lets this session finish projecting, close its runtime, and
    /// deliver (skipping or aborting optional badge queries, with the watchdog
    /// and system expiration still enforced) instead of dropping them to a
    /// fallback. Because runtime shutdown completes before additional enqueues
    /// and resolves `runtimeReleased` directly, a stalled enqueue never blocks
    /// the successor wake.
    func cancelForReplacement() -> Task<Void, Never>? {
        if collectionInFlight, !expirationInProgress {
            replacedDuringOrAfterCollection = true
            abortOptionalBadgeRead()
            return runtimeReleaseBarrierTask()
        }
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        recordDiagnostic(outcome: .replaced)
        beginExpirationCleanup(deliverImmediately: false)
        return runtimeReleaseBarrierTask()
    }

    func beginExpirationCleanup(deliverImmediately: Bool) {
        abortOptionalBadgeRead()
        if expirationInProgress {
            // Hard system expiration can arrive while proactive watchdog
            // cleanup is still awaiting a slow runtime shutdown. Deliver the
            // best prepared primary synchronously before iOS cuts off the
            // handler while letting the shutdown task keep running.
            if deliverImmediately, bestAttemptContent != nil {
                finish(
                    applyingFallbackForTimeout: true,
                    completingExpiration: true
                )
            }
            return
        }
        guard bestAttemptContent != nil else { return }
        expirationInProgress = true
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        recordDiagnostic(outcome: .expired)
        collectionTask?.cancel()
        let shutdownTask = beginRuntimeShutdown()
        if deliverImmediately {
            // Apple's `serviceExtensionTimeWillExpire()` contract gives almost
            // no remaining time: deliver the best prepared primary synchronously
            // while keeping `runtimeShutdownTask` as the barrier for any later
            // wake in this extension process.
            finish(
                applyingFallbackForTimeout: true,
                completingExpiration: true
            )
            return
        }
        let additionalPresentationTask = additionalPresentationTask
        expirationCleanupTask = Task {
            await shutdownTask?.value
            await additionalPresentationTask?.value
            self.finish(
                applyingFallbackForTimeout: true,
                completingExpiration: true
            )
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
        guard let content = bestAttemptContent else {
            finish()
            return
        }

        await priorRuntimeDrain?.value
        if Task.isCancelled || expirationInProgress {
            finish(applyingFallbackForTimeout: true)
            return
        }

        do {
            let runtime = try environment.makeRuntime()
            activeRuntime = runtime
            // Before `start()` opens accounts, whose recorders keep the source they open with.
            _ = try? runtime.setAuditLogSource(source: environment.auditLogSource())
            diagnosticStage = .runtimeCreated
            if Task.isCancelled || expirationInProgress {
                await beginRuntimeShutdown(expected: runtime)?.value
                finish(applyingFallbackForTimeout: true)
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
                // Prepare primary delivery content BEFORE any optional badge
                // read so hard expiration mid-badge-read still delivers the
                // decorated primary rather than falling back.
                preparePrimaryContent(for: decision, in: content)
                if result.status != .failed,
                   !replacedDuringOrAfterCollection,
                   !skipOptionalPostCollectionWork {
                    if let count = await readOptionalApplicationBadgeCount(using: runtime),
                       !Task.isCancelled, !expirationInProgress {
                        applicationBadgeCount = count
                        applyApplicationBadgeCount(count, for: decision, to: content)
                    }
                }
                // Release SQLCipher and the App Group lock BEFORE enqueuing
                // additional Notification Center requests so stalled enqueues
                // cannot hold storage open or block a successor wake.
                await beginRuntimeShutdown(expected: runtime)?.value
                if case .decorate(_, let additionalPresentations) = decision,
                   !Task.isCancelled, !expirationInProgress {
                    let task = startAdditionalPresentations(additionalPresentations)
                    await task?.value
                    self.additionalPresentationTask = nil
                }
                let diagnosticOutcome: NotificationServiceDiagnosticOutcome
                if result.status == .failed {
                    diagnosticOutcome = .failed
                } else {
                    diagnosticStage = .rendered
                    diagnosticOutcome = decision.diagnosticOutcome
                }
                recordDiagnostic(
                    outcome: diagnosticOutcome,
                    notificationCount: result.notifications.count
                )
            } catch {
                recordDiagnostic(outcome: .failed)
                NotificationContentDecorator.applyFallback(to: content)
                await beginRuntimeShutdown(expected: runtime)?.value
            }
        } catch let error as MarmotKitError where error.isRuntimeOwnershipContention {
            recordDiagnostic(outcome: .runtimeOwnershipContention)
            NotificationContentDecorator.applyFallback(to: content)
            finish()
            return
        } catch {
            // Keep the provider payload generic when collection fails. The main
            // app will catch up when it next starts or receives a local event.
            recordDiagnostic(outcome: .failed)
            NotificationContentDecorator.applyFallback(to: content)
        }

        finish()
    }

    private func continueCollection(using runtime: any NotificationServiceWakeRuntime) async -> Bool {
        guard activeRuntime === runtime, !Task.isCancelled, !expirationInProgress else {
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

    private func runtimeReleaseBarrierTask() -> Task<Void, Never>? {
        guard !runtimeReleased else { return nil }
        return Task { @MainActor in
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

    private func readOptionalApplicationBadgeCount(
        using runtime: any NotificationServiceWakeRuntime
    ) async -> Int? {
        guard !replacedDuringOrAfterCollection,
              !skipOptionalPostCollectionWork,
              !expirationInProgress,
              !Task.isCancelled
        else { return nil }

        let badgeTask = Task {
            await runtime.applicationBadgeCount()
        }
        defer { badgeTask.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !replacedDuringOrAfterCollection,
                      !skipOptionalPostCollectionWork,
                      !expirationInProgress,
                      !Task.isCancelled
                else {
                    continuation.resume(returning: nil)
                    return
                }
                optionalBadgeContinuation = continuation
                Task { @MainActor [weak self] in
                    let count = await badgeTask.value
                    self?.resumeOptionalBadgeRead(with: count)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.abortOptionalBadgeRead()
            }
        }
    }

    private func resumeOptionalBadgeRead(with count: Int?) {
        optionalBadgeContinuation?.resume(returning: count)
        optionalBadgeContinuation = nil
    }

    private func abortOptionalBadgeRead() {
        optionalBadgeContinuation?.resume(returning: nil)
        optionalBadgeContinuation = nil
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
        in content: UNMutableNotificationContent
    ) {
        didApplyRenderDecision = true
        switch decision {
        case .decorate(let presentation, _):
            NotificationContentDecorator.apply(presentation, to: content)
            decoratedContent = NotificationCommunicationDecorator.decorated(
                content,
                presentation: presentation,
                avatarData: nil
            )
        case .deliverQuietly:
            NotificationContentDecorator.applyQuietDelivery(to: content)
        case .fallback:
            NotificationContentDecorator.applyFallback(to: content)
        }
    }

    private func applyApplicationBadgeCount(
        _ count: Int,
        for decision: NotificationServiceRenderDecision,
        to content: UNMutableNotificationContent
    ) {
        NotificationContentDecorator.applyApplicationBadgeCount(count, to: content)
        if case .decorate(let presentation, _) = decision {
            decoratedContent = NotificationCommunicationDecorator.decorated(
                content,
                presentation: presentation,
                avatarData: nil
            )
        }
    }

    private func startAdditionalPresentations(
        _ additionalPresentations: [LocalNotificationPresentation]
    ) -> Task<Void, Never>? {
        guard !additionalPresentations.isEmpty else { return nil }
        let applicationBadgeCount = applicationBadgeCount
        let enqueue = environment.enqueueAdditionalPresentation
        let task = Task { [additionalPresentations, applicationBadgeCount] in
            for presentation in additionalPresentations {
                await enqueue(presentation, applicationBadgeCount)
            }
        }
        additionalPresentationTask = task
        return task
    }

    private func finish(
        applyingFallbackForTimeout: Bool = false,
        completingExpiration: Bool = false
    ) {
        guard NotificationServiceTimeoutPolicy.canDeliver(
            expirationInProgress: expirationInProgress,
            completingExpiration: completingExpiration
        ) else { return }
        guard let bestAttemptContent else { return }
        var deliverable: UNNotificationContent = bestAttemptContent
        if NotificationServiceTimeoutPolicy.shouldApplyTimeoutFallback(
            applyingFallbackForTimeout: applyingFallbackForTimeout,
            didApplyRenderDecision: didApplyRenderDecision
        ) {
            NotificationContentDecorator.applyFallback(to: bestAttemptContent)
        } else if let decoratedContent {
            deliverable = decoratedContent
        }
        self.bestAttemptContent = nil
        self.collectionTask = nil
        self.expirationWatchdogTask?.cancel()
        self.expirationWatchdogTask = nil
        self.expirationCleanupTask = nil
        self.additionalPresentationTask = nil
        self.abortOptionalBadgeRead()
        self.collectionInFlight = false
        self.replacedDuringOrAfterCollection = false
        self.skipOptionalPostCollectionWork = false
        self.applicationBadgeCount = nil
        self.didApplyRenderDecision = false
        self.decoratedContent = nil
        if !completingExpiration {
            self.expirationInProgress = false
        }
        let onDelivered = onDeliveredHandler
        onDeliveredHandler = nil
        delivery.deliver(deliverable)
        onDelivered?()
    }
}
