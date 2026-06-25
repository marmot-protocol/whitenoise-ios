import Foundation
import MarmotKit
import UserNotifications

@MainActor
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var collectionTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var additionalPresentationTask: Task<Void, Never>?
    private var activeMarmot: Marmot?
    private var activeMarmotNeedsShutdown = false
    private var didApplyRenderDecision = false
    private let maxNotificationServiceWaitMs = NotificationServiceProjection.maxWakeWaitMs

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        activeMarmot = nil
        activeMarmotNeedsShutdown = false
        additionalPresentationTask = nil
        didApplyRenderDecision = false

        collectionTask = Task { [weak self] in
            await self?.collectAndDecorateNotification()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        collectionTask?.cancel()
        let additionalPresentationTask = additionalPresentationTask
        guard let marmot = takeActiveMarmotForShutdown() else {
            if let additionalPresentationTask {
                expirationTask = Task.detached { [weak self] in
                    await additionalPresentationTask.value
                    await self?.finish(applyingFallbackForTimeout: true)
                }
            } else {
                finish(applyingFallbackForTimeout: true)
            }
            return
        }
        expirationTask = Task.detached { [weak self] in
            let shutdownTask = Task.detached {
                await marmot.shutdown()
            }
            await additionalPresentationTask?.value
            await shutdownTask.value
            await self?.finish(applyingFallbackForTimeout: true)
        }
    }

    private func collectAndDecorateNotification() async {
        guard let content = bestAttemptContent else {
            finish()
            return
        }

        do {
            let marmot = try Marmot(
                rootPath: AppContainerConfig.productionMarmotRoot().path,
                relayUrls: AppContainerConfig.seedRelays
            )
            activeMarmot = marmot
            activeMarmotNeedsShutdown = true
            do {
                try await marmot.start()
                guard activeMarmot === marmot else { return }
                let result = try await marmot.collectNotificationsAfterWake(
                    maxWaitMs: maxNotificationServiceWaitMs,
                    source: .apnsNse
                )
                let decision = NotificationServiceProjection.decision(
                    for: result,
                    localNotificationsEnabled: NotificationServiceSettingsReadPolicy
                        .memoizingLocalNotificationsEnabled { accountRef in
                            NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
                                try marmot.notificationSettings(
                                    accountRef: accountRef
                                ).localNotificationsEnabled
                            }
                        }
                )
                await apply(decision, to: content)
            } catch {
                applyFallback(to: content)
            }
            if let marmot = takeActiveMarmotForShutdown(marmot) {
                await marmot.shutdown()
            }
        } catch {
            // Keep the provider payload generic when collection fails. The main
            // app will catch up when it next starts or receives a local event.
            applyFallback(to: content)
        }

        finish()
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
            let additionalPresentationTask = startAdditionalPresentations(additionalPresentations)
            decorate(content, with: presentation)
            await additionalPresentationTask?.value
            self.additionalPresentationTask = nil
        case .fallback:
            applyFallback(to: content)
        }
    }

    private func decorate(
        _ content: UNMutableNotificationContent,
        with presentation: LocalNotificationPresentation
    ) {
        content.title = presentation.title
        content.body = presentation.body
        content.sound = .default
        content.threadIdentifier = presentation.threadIdentifier
        var userInfo = content.userInfo
        for (key, value) in presentation.userInfo {
            userInfo[key] = value
        }
        content.userInfo = userInfo
    }

    private func startAdditionalPresentations(
        _ additionalPresentations: [LocalNotificationPresentation]
    ) -> Task<Void, Never>? {
        guard !additionalPresentations.isEmpty else { return nil }
        let task = Task { [additionalPresentations] in
            for presentation in additionalPresentations {
                let request = UNNotificationRequest(
                    identifier: presentation.identifier,
                    content: notificationContent(for: presentation),
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
        additionalPresentationTask = task
        return task
    }

    private func notificationContent(
        for presentation: LocalNotificationPresentation
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.body = presentation.body
        content.sound = .default
        content.threadIdentifier = presentation.threadIdentifier
        content.userInfo = presentation.userInfo
        return content
    }

    private func applyFallback(to content: UNMutableNotificationContent) {
        if content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.title = L10n.string("White Noise")
        }
        if content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = L10n.string("New encrypted message")
        }
    }

    private func finish(applyingFallbackForTimeout: Bool = false) {
        guard let contentHandler, let bestAttemptContent else { return }
        if applyingFallbackForTimeout, !didApplyRenderDecision {
            applyFallback(to: bestAttemptContent)
        }
        self.contentHandler = nil
        self.bestAttemptContent = nil
        self.collectionTask = nil
        self.expirationTask = nil
        self.additionalPresentationTask = nil
        self.didApplyRenderDecision = false
        contentHandler(bestAttemptContent)
    }
}
