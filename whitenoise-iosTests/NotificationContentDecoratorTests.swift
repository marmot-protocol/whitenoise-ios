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

    @Test func applyRendersAlertConsistentContentIncludingDefaultSoundAndMergesUserInfo() {
        let content = UNMutableNotificationContent()
        content.userInfo = ["existing": "keep"]

        NotificationContentDecorator.apply(presentation(), to: content)

        #expect(content.title == "Alice")
        #expect(content.body == "hello")
        #expect(content.threadIdentifier == "thread-1")
        #expect(content.sound == UNNotificationSound.default)
        #expect(content.userInfo["existing"] as? String == "keep")
        #expect(content.userInfo["k"] as? String == "v")
    }

    @Test func makeContentAppliesSameDecorationOnFreshContent() {
        let content = NotificationContentDecorator.makeContent(for: presentation())

        #expect(content.title == "Alice")
        #expect(content.body == "hello")
        #expect(content.threadIdentifier == "thread-1")
        #expect(content.sound == UNNotificationSound.default)
        #expect(content.userInfo["k"] as? String == "v")
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
}
