import Foundation
import MarmotKit

enum NotificationServiceRenderDecision: Equatable {
    case decorate(LocalNotificationPresentation, additionalPresentations: [LocalNotificationPresentation])
    case suppress
    case fallback
}

enum NotificationServiceProjection {
    // Keep room for extension startup and fallback delivery before iOS expires
    // the notification service extension.
    static let maxWakeWaitMs: UInt32 = 8_000

    static func decision(for collection: BackgroundNotificationCollectionFfi) -> NotificationServiceRenderDecision {
        switch collection.status {
        case .newData:
            let presentations = collection.notifications
                .filter({ !$0.isFromSelf })
                .sorted(by: { $0.timestampMs > $1.timestampMs })
                .compactMap(LocalNotificationProjection.makePresentation(for:))
            guard let presentation = presentations.first
            else {
                return .suppress
            }
            return .decorate(
                presentation,
                additionalPresentations: Array(presentations.dropFirst())
            )
        case .noData:
            return .suppress
        case .failed:
            return .fallback
        }
    }
}
