import Foundation
import MarmotKit
import OSLog
import UserNotifications

@MainActor
final class NotificationService: UNNotificationServiceExtension {
    private let delivery = OneShotNotificationDelivery()
    private var bestAttemptContent: UNMutableNotificationContent?
    /// Communication-intent copy of the primary content. `updating(from:)`
    /// returns a new immutable content, so it rides in its own slot and
    /// `finish` prefers it unless the timeout fallback rewrote the original.
    private var decoratedContent: UNNotificationContent?
    private var collectionTask: Task<Void, Never>?
    private var expirationWatchdogTask: Task<Void, Never>?
    private var expirationCleanupTask: Task<Void, Never>?
    private var additionalPresentationTask: Task<Void, Never>?
    private var avatarFetchTask: Task<[String: Data], Never>?
    private var activeMarmot: Marmot?
    private var activeMarmotNeedsShutdown = false
    private var applicationBadgeCount: Int?
    private var didApplyRenderDecision = false
    private var diagnosticStartedAt = Date()
    private var diagnosticStage: NotificationServiceDiagnosticStage = .received
    private var didRecordDiagnostic = false
    private var expirationInProgress = false
    private let maxNotificationServiceWaitMs = NotificationServiceProjection.maxWakeWaitMs
    private static let diagnosticLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios.NotificationService",
        category: "notification-service"
    )

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        delivery.reset(handler: contentHandler)
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        activeMarmot = nil
        activeMarmotNeedsShutdown = false
        expirationWatchdogTask?.cancel()
        expirationWatchdogTask = nil
        expirationCleanupTask = nil
        additionalPresentationTask = nil
        avatarFetchTask = nil
        applicationBadgeCount = nil
        didApplyRenderDecision = false
        decoratedContent = nil
        diagnosticStartedAt = Date()
        diagnosticStage = .received
        didRecordDiagnostic = false
        expirationInProgress = false

        collectionTask = Task { [weak self] in
            await self?.collectAndDecorateNotification()
        }
        expirationWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: NotificationServiceTimeoutPolicy.proactiveExpirationDelay)
            guard !Task.isCancelled else { return }
            self?.beginExpirationCleanup()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        beginExpirationCleanup()
    }

    private func beginExpirationCleanup() {
        guard bestAttemptContent != nil, !expirationInProgress else { return }
        expirationInProgress = true
        recordDiagnostic(outcome: .expired)
        collectionTask?.cancel()
        // Unblocks the additional-presentation task: it enqueues immediately
        // with whatever avatars have resolved instead of waiting out the
        // remaining fetch deadlines.
        avatarFetchTask?.cancel()
        let marmot = takeActiveMarmotForShutdown()
        let additionalPresentationTask = additionalPresentationTask
        expirationCleanupTask = Task { [weak self] in
            if let marmot {
                try? await marmot.shutdownAndClose()
            }
            await additionalPresentationTask?.value
            self?.finish(
                applyingFallbackForTimeout: true,
                completingExpiration: true
            )
        }
    }

    private func collectAndDecorateNotification() async {
        guard let content = bestAttemptContent else {
            finish()
            return
        }

        do {
            // An NSE wake is a sub-second drain on cold sockets; it must never
            // persist cursor advancement, or a partial catch-up permanently
            // floors the durable `since` past undelivered events.
            let marmot = try Marmot.newWithCursorPersistence(
                rootPath: AppContainerConfig.productionMarmotRoot().path,
                relayUrls: AppContainerConfig.seedRelays,
                cursorPersistence: .frozen
            )
            activeMarmot = marmot
            activeMarmotNeedsShutdown = true
            diagnosticStage = .runtimeCreated
            if Task.isCancelled {
                if let marmot = takeActiveMarmotForShutdown(marmot) {
                    try? await marmot.shutdownAndClose()
                }
                finish(applyingFallbackForTimeout: true)
                return
            }
            do {
                try await marmot.start()
                diagnosticStage = .runtimeStarted
                guard activeMarmot === marmot else { return }
                let result = try await marmot.collectNotificationsAfterWake(
                    maxWaitMs: maxNotificationServiceWaitMs,
                    source: .apnsNse
                )
                diagnosticStage = .collectionCompleted
                if result.status != .failed {
                    let count = await NotificationServiceStorageReader
                        .applicationBadgeCount(marmot: marmot)
                    guard await continueCollection(using: marmot) else { return }
                    if let count {
                        applicationBadgeCount = count
                        NotificationContentDecorator.applyApplicationBadgeCount(count, to: content)
                    }
                }
                // One shared-defaults read per wake; per-record lookups hit the
                // in-memory snapshots. A nil mode snapshot means the shared suite
                // couldn't be resolved, so delivery fails safe (all suppressed).
                let notifyModeSnapshot = ChatMuteStore.notifyModeSnapshot()
                let contactNicknames = ContactNicknameStore.nicknamesByKey()
                let previewMode = NotificationPreviewStore.mode()
                let accountRefs = Set(result.notifications.map(\.accountRef))
                let enabledByAccountRef = await NotificationServiceStorageReader
                    .localNotificationsEnabled(marmot: marmot, accountRefs: accountRefs)
                guard await continueCollection(using: marmot) else { return }
                let localNotificationsEnabled: (String) -> Bool = { accountRef in
                    enabledByAccountRef[accountRef] ?? true
                }
                let notifyMode: (String, String) -> ChatNotifyMode = { accountIdHex, groupIdHex in
                    ChatMuteStore.notifyMode(
                        accountIdHex: accountIdHex,
                        groupIdHex: groupIdHex,
                        snapshot: notifyModeSnapshot
                    )
                }
                let accountsRequiringArchivedLookup =
                    NotificationPresentationPolicy.accountRefsRequiringArchivedLookup(
                        for: result,
                        localNotificationsEnabled: localNotificationsEnabled,
                        notifyMode: notifyMode
                    )
                let archivedChatKeys = await NotificationServiceStorageReader.archivedChatKeys(
                    marmot: marmot,
                    accountRefs: accountsRequiringArchivedLookup
                )
                guard await continueCollection(using: marmot) else { return }
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
                    notifyMode: notifyMode,
                    nickname: { ownerAccountIdHex, contactAccountIdHex in
                        ContactNicknameStore.nickname(
                            ownerAccountIdHex: ownerAccountIdHex,
                            contactAccountIdHex: contactAccountIdHex,
                            in: contactNicknames
                        )
                    },
                    previewMode: previewMode
                )
                // An empty wake can't be attributed: the engine drops
                // disabled accounts' records at ingest, so `.noData` is
                // ambiguous between "nothing existed" and "records were
                // suppressed". Account-wide inference gets both directions
                // wrong, so the fallback stays audible until the engine
                // reports suppressed records explicitly.
                await apply(decision, to: content)
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
                applyFallback(to: content)
            }
            if let marmot = takeActiveMarmotForShutdown(marmot) {
                try? await marmot.shutdownAndClose()
            }
        } catch let error as MarmotKitError where error.isRuntimeOwnershipContention {
            recordDiagnostic(outcome: .runtimeOwnershipContention)
            applyFallback(to: content)
            finish()
            return
        } catch {
            // Keep the provider payload generic when collection fails. The main
            // app will catch up when it next starts or receives a local event.
            recordDiagnostic(outcome: .failed)
            applyFallback(to: content)
        }

        finish()
    }

    private func continueCollection(using marmot: Marmot) async -> Bool {
        guard activeMarmot === marmot, !Task.isCancelled else {
            if let marmot = takeActiveMarmotForShutdown(marmot) {
                try? await marmot.shutdownAndClose()
            }
            return false
        }
        return true
    }

    private func recordDiagnostic(
        outcome: NotificationServiceDiagnosticOutcome,
        notificationCount: Int = 0
    ) {
        guard !didRecordDiagnostic else { return }
        didRecordDiagnostic = true
        let elapsed = max(0, Date().timeIntervalSince(diagnosticStartedAt))
        let durationMilliseconds = Int((elapsed * 1_000).rounded())
        let snapshot = NotificationServiceDiagnosticSnapshot(
            recordedAt: Date(),
            durationMilliseconds: durationMilliseconds,
            stage: diagnosticStage,
            outcome: outcome,
            notificationCount: notificationCount
        )
        NotificationServiceDiagnostics.recordInSharedContainer(snapshot)
        Self.diagnosticLog.info(
            "wake_finished outcome=\(outcome.rawValue, privacy: .public) stage=\(self.diagnosticStage.rawValue, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public) notification_count=\(notificationCount, privacy: .public)"
        )
    }

    private func takeActiveMarmotForShutdown(_ marmot: Marmot? = nil) -> Marmot? {
        guard let active = activeMarmot else { return nil }
        if let marmot, active !== marmot { return nil }
        activeMarmot = nil
        defer { activeMarmotNeedsShutdown = false }
        guard activeMarmotNeedsShutdown else { return nil }
        return active
    }

    private func apply(
        _ decision: NotificationServiceRenderDecision,
        to content: UNMutableNotificationContent
    ) async {
        didApplyRenderDecision = true
        switch decision {
        case .decorate(let presentation, let additionalPresentations):
            // Enrich the deliverable content BEFORE any avatar work: an
            // expiration that lands mid-fetch must deliver the decorated
            // title/body, just without the intent image.
            decorate(content, with: presentation)
            // The additional-presentation task must exist before any avatar
            // await — expiration finishes without one, and these records are
            // already consumed from the background cursor. It awaits the
            // shared fetch internally; cancelling that fetch releases it to
            // enqueue with whatever resolved.
            let avatarFetch = Task { await Self.fetchAvatars(for: [presentation] + additionalPresentations) }
            avatarFetchTask = avatarFetch
            let additionalPresentationTask = startAdditionalPresentations(additionalPresentations) {
                await avatarFetch.value
            }
            let avatarsByUrl = await avatarFetch.value
            decoratedContent = NotificationCommunicationDecorator.decorated(
                content,
                presentation: presentation,
                avatarData: presentation.senderPictureUrl.flatMap { avatarsByUrl[$0] }
            )
            await additionalPresentationTask?.value
            self.additionalPresentationTask = nil
            avatarFetchTask = nil
        case .deliverQuietly:
            applyQuietDelivery(to: content)
        case .fallback:
            applyFallback(to: content)
        }
    }

    private func decorate(
        _ content: UNMutableNotificationContent,
        with presentation: LocalNotificationPresentation
    ) {
        NotificationContentDecorator.apply(presentation, to: content)
    }

    private func startAdditionalPresentations(
        _ additionalPresentations: [LocalNotificationPresentation],
        avatarsByUrl: @escaping @Sendable () async -> [String: Data]
    ) -> Task<Void, Never>? {
        guard !additionalPresentations.isEmpty else { return nil }
        let applicationBadgeCount = applicationBadgeCount
        let task = Task { [additionalPresentations, applicationBadgeCount] in
            let avatars = await avatarsByUrl()
            for presentation in additionalPresentations {
                let content = NotificationCommunicationDecorator.decorated(
                    NotificationContentDecorator.makeContent(
                        for: presentation,
                        applicationBadgeCount: applicationBadgeCount
                    ),
                    presentation: presentation,
                    avatarData: presentation.senderPictureUrl.flatMap { avatars[$0] }
                )
                let request = UNNotificationRequest(
                    identifier: presentation.identifier,
                    content: content,
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
        additionalPresentationTask = task
        return task
    }

    /// Resolves each distinct sender avatar once per wake. Each fetch's
    /// deadline is clamped to what remains of the aggregate budget, so the
    /// total avatar wait is a hard bound rather than a loop-entry check that
    /// a late fetch could overshoot; cache hits are instant and unbudgeted.
    private static func fetchAvatars(
        for presentations: [LocalNotificationPresentation]
    ) async -> [String: Data] {
        var distinct: [String] = []
        for presentation in presentations {
            if let url = presentation.senderPictureUrl, !distinct.contains(url) {
                distinct.append(url)
            }
        }
        var avatars: [String: Data] = [:]
        let clock = ContinuousClock()
        let start = clock.now
        for url in distinct.prefix(3) {
            guard !Task.isCancelled,
                  let deadline = NotificationCommunicationDecorator.avatarFetchDeadline(
                      elapsed: clock.now - start
                  )
            else { break }
            if let data = await NotificationCommunicationDecorator.avatarData(
                for: url,
                deadline: deadline
            ) {
                avatars[url] = data
            }
        }
        return avatars
    }

    /// Without the filtering entitlement the extension cannot drop the alert
    /// that woke it, so a fully muted wake keeps the generic content but sheds
    /// its banner and sound: the record lands silently in Notification Center.
    private func applyQuietDelivery(to content: UNMutableNotificationContent) {
        applyFallback(to: content)
        content.userInfo[LocalNotificationProjection.deliveryDispositionKey] =
            LocalNotificationProjection.quietDisposition
        content.sound = nil
        content.interruptionLevel = .passive
    }

    private func applyFallback(to content: UNMutableNotificationContent) {
        content.userInfo[LocalNotificationProjection.deliveryDispositionKey] =
            LocalNotificationProjection.fallbackDisposition
        if content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.title = L10n.string("White Noise")
        }
        if content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = L10n.string("New encrypted message")
        }
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
            applyFallback(to: bestAttemptContent)
        } else if let decoratedContent {
            deliverable = decoratedContent
        }
        self.bestAttemptContent = nil
        self.collectionTask = nil
        self.expirationWatchdogTask?.cancel()
        self.expirationWatchdogTask = nil
        self.expirationCleanupTask = nil
        self.additionalPresentationTask = nil
        self.avatarFetchTask = nil
        self.applicationBadgeCount = nil
        self.didApplyRenderDecision = false
        self.decoratedContent = nil
        self.expirationInProgress = false
        delivery.deliver(deliverable)
    }
}
