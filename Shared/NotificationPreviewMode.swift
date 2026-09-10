import Foundation

/// How much of an incoming message a local notification may reveal.
///
/// iOS renders notification content as a banner, keeps it in Notification
/// Center, and shows it on the Lock Screen, so for an end-to-end encrypted
/// messenger the notification body is plaintext that has left the app's
/// control. Raw values are persisted; do not rename cases.
nonisolated enum NotificationPreviewMode: String, CaseIterable, Sendable {
    /// Sender (or group) name plus the decrypted message text.
    case senderAndMessage
    /// Who the message is from, never what it says.
    case senderOnly
    /// Neither sender nor contents: the same generic text the extension
    /// delivers when it has no local state to render.
    case generic

    var revealsSenderIdentity: Bool {
        self != .generic
    }

    var revealsMessageContent: Bool {
        self == .senderAndMessage
    }
}
