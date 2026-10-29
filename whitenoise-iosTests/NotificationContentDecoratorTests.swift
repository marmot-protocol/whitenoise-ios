import Foundation
import Testing
import UserNotifications
@testable import whitenoise_ios

struct NotificationContentDecoratorTests {
    private func presentation() -> LocalNotificationPresentation {
        LocalNotificationPresentation(
            identifier: "id-1",
            threadIdentifier: "thread-1",
            title: "Alice",
            body: "hello",
            route: LocalNotificationRoute(
                accountRef: "acct",
                groupIdHex: "group",
                notificationKey: "key",
                messageIdHex: "msg"
            ),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            userInfo: ["k": "v"]
        )
    }

    @Test func applyRendersAudibleContentByDefaultAndMergesUserInfo() {
        let content = UNMutableNotificationContent()
        content.userInfo = ["existing": "keep"]

        NotificationContentDecorator.apply(presentation(), to: content)

        #expect(content.title == "Alice")
        #expect(content.body == "hello")
        #expect(content.threadIdentifier == "thread-1")
        #expect(content.targetContentIdentifier == "id-1")
        #expect(content.sound == UNNotificationSound.default)
        #expect(content.userInfo["existing"] as? String == "keep")
        #expect(content.userInfo["k"] as? String == "v")
    }

    @Test func makeContentAppliesSameDecorationOnFreshContent() {
        let content = NotificationContentDecorator.makeContent(
            for: presentation(),
            applicationBadgeCount: 7
        )

        #expect(content.title == "Alice")
        #expect(content.body == "hello")
        #expect(content.threadIdentifier == "thread-1")
        #expect(content.targetContentIdentifier == "id-1")
        #expect(content.sound == UNNotificationSound.default)
        #expect(content.interruptionLevel == .active)
        #expect(content.userInfo["k"] as? String == "v")
        #expect(content.badge == 7)
    }

    @Test func quietContentKeepsItsThreadAndBadgeWithoutSoundOrInterruption() {
        let content = NotificationContentDecorator.makeContent(
            for: presentation(),
            applicationBadgeCount: 7,
            alerting: .quiet
        )

        #expect(content.title == "Alice")
        #expect(content.body == "hello")
        #expect(content.threadIdentifier == "thread-1")
        #expect(content.targetContentIdentifier == "id-1")
        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .passive)
        #expect(content.userInfo["k"] as? String == "v")
        #expect(content.badge == 7)
    }

    @Test func quietAlertingSilencesContentThatArrivedWithASound() {
        let content = UNMutableNotificationContent()
        content.sound = .default

        NotificationContentDecorator.applyAlerting(.quiet, to: content)

        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .passive)
    }

    @Test func communicationDecorationPreservesQuietAlerting() {
        var notification = presentation()
        notification.senderName = "Alice"
        notification.senderAccountIdHex = "alice-id"
        let content = NotificationContentDecorator.makeContent(
            for: notification,
            alerting: .quiet
        )

        let decorated = NotificationCommunicationDecorator.decorated(
            content,
            presentation: notification,
            avatarData: nil
        )

        #expect(decorated.sound == nil)
        #expect(decorated.interruptionLevel == .passive)
    }

    @Test func zeroApplicationBadgeClearsTheIconCount() {
        let content = UNMutableNotificationContent()
        content.badge = 9

        NotificationContentDecorator.applyApplicationBadgeCount(0, to: content)

        #expect(content.badge == 0)
    }

    @Test func communicationDecorationPreservesApplicationBadge() {
        var notification = presentation()
        notification.senderName = "Alice"
        notification.senderAccountIdHex = "alice-id"
        let content = NotificationContentDecorator.makeContent(
            for: notification,
            applicationBadgeCount: 6
        )

        let decorated = NotificationCommunicationDecorator.decorated(
            content,
            presentation: notification,
            avatarData: nil
        )

        #expect(decorated.badge == 6)
    }

    @Test func timeoutFallbackAppliesOnlyWhenNoRenderDecisionWasApplied() {
        #expect(NotificationServiceTimeoutPolicy.shouldApplyTimeoutFallback(
            applyingFallbackForTimeout: true,
            didApplyRenderDecision: false
        ))
        #expect(!NotificationServiceTimeoutPolicy.shouldApplyTimeoutFallback(
            applyingFallbackForTimeout: true,
            didApplyRenderDecision: true
        ))
        #expect(!NotificationServiceTimeoutPolicy.shouldApplyTimeoutFallback(
            applyingFallbackForTimeout: false,
            didApplyRenderDecision: false
        ))
    }

    @Test func timeoutDeliveryWaitsForExpirationCleanup() {
        #expect(NotificationServiceTimeoutPolicy.canDeliver(
            expirationInProgress: false,
            completingExpiration: false
        ))
        #expect(!NotificationServiceTimeoutPolicy.canDeliver(
            expirationInProgress: true,
            completingExpiration: false
        ))
        #expect(NotificationServiceTimeoutPolicy.canDeliver(
            expirationInProgress: true,
            completingExpiration: true
        ))
    }

    @Test func notificationServiceDiagnosticSnapshotRoundTripsWithoutMessageData() {
        let suiteName = "notification-service-diagnostics-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = NotificationServiceDiagnosticSnapshot(
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 812,
            stage: .rendered,
            outcome: .decorated,
            notificationCount: 2
        )

        NotificationServiceDiagnostics.record(snapshot, defaults: defaults)

        #expect(NotificationServiceDiagnostics.lastSnapshot(defaults: defaults) == snapshot)
    }

    /// The extension can't drop the alert that woke it, so a wake with no local
    /// presentation still says something: never a blank notification.
    @Test(arguments: ["", "   ", "\n"])
    func fallbackFillsBlankCopyWithTheGenericTitleAndBody(_ blank: String) {
        let content = UNMutableNotificationContent()
        content.title = blank
        content.body = blank

        NotificationContentDecorator.applyFallback(to: content)

        #expect(content.title == L10n.string("White Noise"))
        #expect(content.body == L10n.string("New encrypted message"))
        #expect(content.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.fallbackDisposition)
    }

    @Test func fallbackKeepsCopyThePushAlreadyCarries() {
        let content = UNMutableNotificationContent()
        content.title = "Server title"
        content.body = "Server body"

        NotificationContentDecorator.applyFallback(to: content)

        #expect(content.title == "Server title")
        #expect(content.body == "Server body")
    }

    /// A fully muted wake keeps the generic copy but lands silently in
    /// Notification Center: no sound, no banner.
    @Test func quietDeliveryIsSilentGenericContent() {
        let content = UNMutableNotificationContent()
        content.sound = .default

        NotificationContentDecorator.applyQuietDelivery(to: content)

        #expect(content.title == L10n.string("White Noise"))
        #expect(content.body == L10n.string("New encrypted message"))
        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .passive)
        #expect(content.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.quietDisposition)
    }
}
