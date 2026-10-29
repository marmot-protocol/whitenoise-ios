import Foundation
import UserNotifications

enum NotificationContentDecorator {
    /// A quiet presentation lands in Notification Center, in its chat's stack,
    /// without a banner, sound, or lit screen.
    enum Alerting {
        case audible
        case quiet
    }

    static func apply(
        _ presentation: LocalNotificationPresentation,
        to content: UNMutableNotificationContent,
        applicationBadgeCount: Int? = nil,
        alerting: Alerting = .audible
    ) {
        content.title = presentation.title
        content.body = presentation.body
        applyAlerting(alerting, to: content)
        content.threadIdentifier = presentation.threadIdentifier
        content.targetContentIdentifier = presentation.identifier
        if let applicationBadgeCount {
            applyApplicationBadgeCount(applicationBadgeCount, to: content)
        }
        if let categoryIdentifier = presentation.categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        var userInfo = content.userInfo
        for (key, value) in presentation.userInfo {
            userInfo[key] = value
        }
        content.userInfo = userInfo
    }

    static func makeContent(
        for presentation: LocalNotificationPresentation,
        applicationBadgeCount: Int? = nil,
        alerting: Alerting = .audible
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        apply(
            presentation,
            to: content,
            applicationBadgeCount: applicationBadgeCount,
            alerting: alerting
        )
        return content
    }

    static func applyAlerting(
        _ alerting: Alerting,
        to content: UNMutableNotificationContent
    ) {
        switch alerting {
        case .audible:
            content.sound = .default
        case .quiet:
            content.sound = nil
            content.interruptionLevel = .passive
        }
    }

    /// Content for a wake the extension can't present from local state. It
    /// cannot drop the alert that woke it, so empty copy becomes the generic
    /// title and body rather than a blank notification.
    static func applyFallback(to content: UNMutableNotificationContent) {
        content.userInfo[LocalNotificationProjection.deliveryDispositionKey] =
            LocalNotificationProjection.fallbackDisposition
        if content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.title = L10n.string("White Noise")
        }
        if content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = L10n.string("New encrypted message")
        }
    }

    /// Without the filtering entitlement the extension cannot drop the alert
    /// that woke it, so a fully muted wake keeps the generic content but sheds
    /// its banner and sound: the record lands silently in Notification Center.
    static func applyQuietDelivery(to content: UNMutableNotificationContent) {
        applyFallback(to: content)
        content.userInfo[LocalNotificationProjection.deliveryDispositionKey] =
            LocalNotificationProjection.quietDisposition
        applyAlerting(.quiet, to: content)
    }

    static func applyApplicationBadgeCount(
        _ count: Int,
        to content: UNMutableNotificationContent
    ) {
        content.badge = NSNumber(value: max(count, 0))
    }
}
