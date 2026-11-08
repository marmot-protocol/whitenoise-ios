import Foundation
import UserNotifications

/// What a notification response resolved to. `openChat` is the default tap;
/// the other cases run against the runtime without foregrounding the app.
enum NotificationActionOperation: Equatable {
    case openChat(LocalNotificationRoute)
    case reply(LocalNotificationRoute, text: String)
    /// A reply over the protocol's max length: nothing is sent and the user
    /// is told it failed, like any other unsent reply (#1276).
    case rejectedReply(LocalNotificationRoute)
    case markRead(LocalNotificationRoute, messageIdHex: String)
}

/// Pure decision point mapping a notification response (action identifier +
/// inline text) onto an operation, so the routing is testable without
/// constructing `UNNotificationResponse`.
nonisolated enum NotificationActionRouting {
    static func operation(
        actionIdentifier: String,
        userText: String?,
        route: LocalNotificationRoute
    ) -> NotificationActionOperation? {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            return .openChat(route)
        case NotificationActionCategory.replyActionIdentifier:
            guard let text = outgoingReplyText(userText) else { return nil }
            guard OutgoingSendSizePolicy.admitsText(text) else { return .rejectedReply(route) }
            return .reply(route, text: text)
        case NotificationActionCategory.markReadActionIdentifier:
            guard let messageIdHex = route.messageIdHex, !messageIdHex.isEmpty else { return nil }
            return .markRead(route, messageIdHex: messageIdHex)
        default:
            // Dismiss and unknown actions carry no work.
            return nil
        }
    }

    /// Mirrors the composer's outgoing-text rules: trimmed and non-empty.
    /// Length is checked separately so oversized text is never shortened.
    static func outgoingReplyText(_ userText: String?) -> String? {
        guard let trimmed = userText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
