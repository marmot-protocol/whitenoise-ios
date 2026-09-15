import SwiftUI

/// User-facing copy for the notification preview modes. It lives in the app
/// target because the Notification Service Extension renders no settings UI.
extension NotificationPreviewMode {
    var label: LocalizedStringKey {
        switch self {
        case .senderAndMessage:
            "Sender and Message"
        case .senderOnly:
            "Sender Only"
        case .generic:
            "Generic"
        }
    }

    /// The body the notification actually carries in this mode, composed from
    /// the very keys `LocalNotificationProjection` emits so the example cannot
    /// drift from the delivery in any locale. The sample is a group chat,
    /// the shape where all three modes still produce a distinct body.
    var example: String {
        let sender = L10n.string("Mom")
        switch self {
        case .senderAndMessage:
            return L10n.formatted("%@: %@", sender, L10n.string("Good morning!"))
        case .senderOnly:
            return L10n.formatted("%@ sent a message", sender)
        case .generic:
            return LocalNotificationProjection.genericContentText().body
        }
    }
}
