import Foundation
import MarmotKit
import UserNotifications

@MainActor
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var collectionTask: Task<Void, Never>?
    private let maxNotificationServiceWaitMs = NotificationServiceProjection.maxWakeWaitMs

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        collectionTask = Task { [weak self] in
            await self?.collectAndDecorateNotification()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        collectionTask?.cancel()
        finish()
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
            do {
                try await marmot.start()
                let result = try await marmot.collectNotificationsAfterWake(
                    maxWaitMs: maxNotificationServiceWaitMs,
                    source: .apnsNse
                )
                await apply(NotificationServiceProjection.decision(for: result), to: content)
            } catch {
                applyFallback(to: content)
            }
            await marmot.shutdown()
        } catch {
            // Keep the provider payload generic when collection fails. The main
            // app will catch up when it next starts or receives a local event.
            applyFallback(to: content)
        }

        finish()
    }

    private func apply(
        _ decision: NotificationServiceRenderDecision,
        to content: UNMutableNotificationContent
    ) async {
        switch decision {
        case .decorate(let presentation, let additionalPresentations):
            decorate(content, with: presentation)
            await scheduleAdditionalPresentations(additionalPresentations)
        case .suppress:
            bestAttemptContent = UNMutableNotificationContent()
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
        content.threadIdentifier = presentation.threadIdentifier
        var userInfo = content.userInfo
        for (key, value) in presentation.userInfo {
            userInfo[key] = value
        }
        content.userInfo = userInfo
    }

    private func scheduleAdditionalPresentations(
        _ additionalPresentations: [LocalNotificationPresentation]
    ) async {
        for presentation in additionalPresentations {
            guard !Task.isCancelled else { return }
            let request = UNNotificationRequest(
                identifier: presentation.identifier,
                content: notificationContent(for: presentation),
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
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
            content.title = L10n.string("Darkmatter")
        }
        if content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = L10n.string("New encrypted message")
        }
    }

    private func finish() {
        guard let contentHandler, let bestAttemptContent else { return }
        self.contentHandler = nil
        self.bestAttemptContent = nil
        contentHandler(bestAttemptContent)
    }
}
