import Foundation
import MarmotKit

enum NotificationServiceRenderDecision: Equatable {
    case decorate(LocalNotificationPresentation, additionalPresentations: [LocalNotificationPresentation])
    case fallback
}

nonisolated enum NotificationServiceProjection {
    // Keep room for extension startup and fallback delivery before iOS expires
    // the notification service extension.
    static let maxWakeWaitMs: UInt32 = 8_000

    static func decision(
        for collection: BackgroundNotificationCollectionFfi,
        localNotificationsEnabled: (String) -> Bool = { _ in true }
    ) -> NotificationServiceRenderDecision {
        switch collection.status {
        case .newData:
            let presentations = collection.notifications
                .filter({ !$0.isFromSelf && localNotificationsEnabled($0.accountRef) })
                .sorted(by: { $0.timestampMs > $1.timestampMs })
                .compactMap(LocalNotificationProjection.makePresentation(for:))
            guard let presentation = presentations.first
            else {
                // An NSE cannot cancel an alerting APNS push after delivery; a
                // generic fallback is safer than handing iOS blank content.
                return .fallback
            }
            return .decorate(
                presentation,
                additionalPresentations: Array(presentations.dropFirst())
            )
        case .noData:
            return .fallback
        case .failed:
            return .fallback
        }
    }
}
