import Foundation
import MarmotKit

nonisolated struct LocalNotificationRoute: Equatable, Hashable {
    let accountRef: String
    let groupIdHex: String
    let notificationKey: String
    let messageIdHex: String?
}

nonisolated struct LocalNotificationPresentation: Equatable {
    let identifier: String
    let threadIdentifier: String
    let title: String
    let body: String
    let route: LocalNotificationRoute
    let timestamp: Date
    let userInfo: [String: String]
    // Defaulted so display-only presentations (summaries, failure fallbacks)
    // stay action-free without touching every construction site.
    var categoryIdentifier: String? = nil
    // Communication-notification decoration inputs; defaulted so summaries and
    // fallbacks stay undecorated. The picture URL is pre-sanitized.
    var senderName: String? = nil
    var senderAccountIdHex: String? = nil
    var senderPictureUrl: String? = nil
    var isGroupConversation: Bool = false
}

/// Projects Marmot's per-account unread aggregates into the single numeric
/// badge iOS can render on the app icon. Marmot's aggregate carries pending
/// invites and manual-only reminders without overlapping message totals.
nonisolated enum ApplicationBadgeCountProjection {
    static func count<S: Sequence>(for summaries: S) -> Int
    where S.Element == AccountUnreadFfi {
        var total: UInt64 = 0
        for summary in summaries {
            let contribution = contribution(for: summary)
            let (sum, overflow) = total.addingReportingOverflow(contribution)
            total = overflow ? UInt64.max : sum
        }
        return Int(min(total, UInt64(Int.max)))
    }

    static func contribution(for summary: AccountUnreadFfi) -> UInt64 {
        let (count, overflow) = summary.unreadCount.addingReportingOverflow(
            summary.attentionOnlyConversations
        )
        let boundedCount = overflow ? UInt64.max : count
        return boundedCount == 0 && summary.hasUnread ? 1 : boundedCount
    }
}

nonisolated enum LocalNotificationProjection {
    static let accountRefKey = "dm_account_ref"
    static let groupIdHexKey = "dm_group_id_hex"
    static let notificationKeyKey = "dm_notification_key"
    static let messageIdHexKey = "dm_message_id_hex"
    static let isMentionKey = "dm_is_mention"
    static let accountIdHexKey = "dm_account_id_hex"
    static let deliveryDispositionKey = "dm_delivery_disposition"
    static let quietDisposition = "quiet"
    static let fallbackDisposition = "fallback"
    static let actionFailureDisposition = "action_failure"

    private static let maxPreviewLength = 240

    /// `nickname` resolves the viewer's private label for a (owner, contact)
    /// pair — the same App-Group-backed override the in-app UI reads — so a set
    /// nickname wins over the kind:0 sender name in notification titles too.
    /// Defaults to none so the many test/summary call sites stay unchanged.
    ///
    /// `previewMode` is the single redaction point for every delivery path: the
    /// foreground presenter, the extension's primary content, its additional
    /// presentations, and overflow summaries all build their content here, so a
    /// presentation that carries no sender or preview cannot leak one
    /// downstream. It defaults to the fully revealing mode to match the
    /// permissive defaults of the other policy inputs; the two production call
    /// sites pass `NotificationPreviewStore.mode()`.
    static func makePresentation(
        for update: NotificationUpdateFfi,
        nickname: (String, String) -> String? = { _, _ in nil },
        previewMode: NotificationPreviewMode = .senderAndMessage
    ) -> LocalNotificationPresentation? {
        guard !update.isFromSelf else { return nil }

        let route = LocalNotificationRoute(
            accountRef: update.accountRef,
            groupIdHex: update.groupIdHex,
            notificationKey: notificationIdentifier(for: update),
            messageIdHex: update.messageIdHex
        )

        let senderName = displayName(
            for: update.sender,
            nickname: nickname(update.accountIdHex, update.sender.accountIdHex)
        )
        // A withheld preview reuses the existing "no preview text" wording
        // ("Alice sent a message", "Alice mentioned you"), so sender-only
        // delivery needs no separate copy.
        let preview = previewMode.revealsMessageContent
            ? notificationPreview(update.previewText)
            : nil
        let content = previewMode.revealsSenderIdentity
            ? contentText(
                trigger: update.trigger,
                isDm: update.isDm,
                isMention: update.isMention,
                senderName: senderName,
                groupName: ContentSanitizer.groupName(update.groupName),
                preview: preview
            )
            : genericContentText()

        return LocalNotificationPresentation(
            identifier: route.notificationKey,
            threadIdentifier: threadIdentifier(for: update),
            title: content.title,
            body: content.body,
            route: route,
            timestamp: Date(timeIntervalSince1970: TimeInterval(update.timestampMs) / 1000),
            userInfo: userInfo(for: route).merging(
                [
                    isMentionKey: update.isMention ? "1" : "0",
                    accountIdHexKey: update.accountIdHex,
                ],
                uniquingKeysWith: { _, new in new }
            ),
            categoryIdentifier: NotificationActionCategory.identifier(
                trigger: update.trigger,
                messageIdHex: update.messageIdHex
            ),
            // Dropping the sender fields is what keeps the generic mode out of
            // the communication intent: the decorator returns the content
            // untouched without a sender name, so no name, avatar, or intent
            // `content` is donated, and no avatar is fetched.
            senderName: previewMode.revealsSenderIdentity ? senderName : nil,
            senderAccountIdHex: previewMode.revealsSenderIdentity ? update.sender.accountIdHex : nil,
            senderPictureUrl: previewMode.revealsSenderIdentity
                ? ContentSanitizer.imageURL(update.sender.pictureUrl)?.absoluteString
                : nil,
            isGroupConversation: previewMode.revealsSenderIdentity && !update.isDm
        )
    }

    /// Indistinguishable from the extension's fallback content, so a generic
    /// notification does not disclose that local state existed for it.
    static func genericContentText() -> (title: String, body: String) {
        (title: L10n.string("White Noise"), body: L10n.string("New encrypted message"))
    }

    /// Mention bit persisted alongside the route so `willPresent` can
    /// re-evaluate a mode change against the original message, not a guess.
    /// Absent (pre-upgrade notifications) reads as a mention so only an
    /// explicit non-mention is suppressible by a later mentions-only switch.
    static func isMention(from userInfo: [AnyHashable: Any]) -> Bool {
        guard let raw = stringValue(userInfo[isMentionKey]) else { return true }
        return raw != "0"
    }

    static func accountIdHex(from userInfo: [AnyHashable: Any]) -> String? {
        guard let value = stringValue(userInfo[accountIdHexKey]), !value.isEmpty else { return nil }
        return value
    }

    static func isQuietOrFallback(from userInfo: [AnyHashable: Any]) -> Bool {
        guard let disposition = stringValue(userInfo[deliveryDispositionKey]) else { return false }
        return disposition == quietDisposition || disposition == fallbackDisposition
    }

    static func isActionFailure(from userInfo: [AnyHashable: Any]) -> Bool {
        stringValue(userInfo[deliveryDispositionKey]) == actionFailureDisposition
    }

    static func route(from userInfo: [AnyHashable: Any]) -> LocalNotificationRoute? {
        guard let accountRef = stringValue(userInfo[accountRefKey]), !accountRef.isEmpty,
              let groupIdHex = stringValue(userInfo[groupIdHexKey]), !groupIdHex.isEmpty,
              let notificationKey = stringValue(userInfo[notificationKeyKey]), !notificationKey.isEmpty
        else { return nil }

        return LocalNotificationRoute(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            notificationKey: notificationKey,
            messageIdHex: stringValue(userInfo[messageIdHexKey])
        )
    }

    static func userInfo(for route: LocalNotificationRoute) -> [String: String] {
        var userInfo = [
            accountRefKey: route.accountRef,
            groupIdHexKey: route.groupIdHex,
            notificationKeyKey: route.notificationKey
        ]
        if let messageIdHex = route.messageIdHex {
            userInfo[messageIdHexKey] = messageIdHex
        }
        return userInfo
    }

    private static func contentText(
        trigger: NotificationTriggerFfi,
        isDm: Bool,
        isMention: Bool,
        senderName: String,
        groupName: String?,
        preview: String?
    ) -> (title: String, body: String) {
        switch trigger {
        case .groupInvite:
            return (
                title: L10n.string("Group invite"),
                body: groupName.map { L10n.formatted("Invitation to %@", $0) }
                    ?? L10n.string("Open White Noise to view the invite")
            )
        case .removedFromGroup:
            return (
                title: groupName ?? L10n.string("White Noise"),
                body: L10n.string("You were removed from this chat.")
            )
        case .madeAdmin:
            return (
                title: groupName ?? L10n.string("White Noise"),
                body: L10n.string("You are now an admin.")
            )
        case .removedAsAdmin:
            return (
                title: groupName ?? L10n.string("White Noise"),
                body: L10n.string("You are no longer an admin.")
            )
        case .newMessage:
            if isDm {
                return (title: senderName, body: preview ?? L10n.string("New encrypted message"))
            }
            if isMention {
                return (
                    title: groupName ?? L10n.string("Group message"),
                    body: preview.map { L10n.formatted("%@ mentioned you: %@", senderName, $0) }
                        ?? L10n.formatted("%@ mentioned you", senderName)
                )
            }
            return (
                title: groupName ?? L10n.string("Group message"),
                body: preview.map { L10n.formatted("%@: %@", senderName, $0) }
                    ?? L10n.formatted("%@ sent a message", senderName)
            )
        }
    }

    private static func displayName(for user: NotificationUserFfi, nickname: String?) -> String {
        // A private nickname overrides the kind:0 sender name; it is already
        // sanitized at the store boundary but re-checked here for safety.
        if let nickname = ContentSanitizer.displayName(nickname) {
            return nickname
        }
        if let name = ContentSanitizer.displayName(user.displayName) {
            return name
        }
        if user.accountIdHex.isEmpty {
            return L10n.string("Someone")
        }
        return IdentityFormatter.short(user.accountIdHex)
    }

    private static func sanitizedPreview(_ raw: String?) -> String? {
        ContentSanitizer.compactSingleLine(raw, maxLength: maxPreviewLength)
    }

    private static func notificationPreview(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let label = RemoteGiphyMedia.envelopePreviewText(for: raw) {
            return label
        }
        return sanitizedPreview(raw)
    }

    private static func notificationIdentifier(for update: NotificationUpdateFfi) -> String {
        if !update.notificationKey.isEmpty {
            return update.notificationKey
        }
        if let messageIdHex = update.messageIdHex, !messageIdHex.isEmpty {
            return "\(update.accountRef):\(update.groupIdHex):\(messageIdHex)"
        }
        return "\(update.accountRef):\(update.groupIdHex):\(update.timestampMs)"
    }

    private static func threadIdentifier(for update: NotificationUpdateFfi) -> String {
        if !update.conversationKey.isEmpty {
            return update.conversationKey
        }
        return "\(update.accountRef):\(update.groupIdHex)"
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }
}
