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

    /// A deterministic sample of what the mode actually delivers. The two
    /// withholding modes quote the real generic body, so the example cannot
    /// promise wording the notification will not use.
    var example: LocalizedStringKey {
        switch self {
        case .senderAndMessage:
            "Maya Chen · Can you send the latest version?"
        case .senderOnly:
            "Maya Chen · New encrypted message"
        case .generic:
            "White Noise · New encrypted message"
        }
    }
}
