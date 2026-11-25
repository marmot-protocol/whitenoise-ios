import Foundation
import UserNotifications

nonisolated final class NotificationService: UNNotificationServiceExtension {
    /// Shared across the extension process so consecutive pushes serialize
    /// runtime teardown even if iOS constructs a fresh extension instance.
    private static let coordinator = NotificationServiceWakeCoordinator(environment: .live)
    private let instanceID = UUID()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        Self.coordinator.didReceive(
            request,
            ownerID: instanceID,
            withContentHandler: contentHandler
        )
    }

    override func serviceExtensionTimeWillExpire() {
        Self.coordinator.serviceExtensionTimeWillExpire(ownerID: instanceID)
    }
}
