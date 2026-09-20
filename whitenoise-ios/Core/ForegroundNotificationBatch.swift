import Foundation

/// Only the main app uses this planner. iOS owns delivery of the pending request.
nonisolated struct ForegroundNotificationBatch {
    struct Key: Hashable {
        let account: String
        let group: String
    }
    struct Window {
        let deadline: TimeInterval
        var keys: Set<String>
        var count = 0
        var containsMention: Bool
        var latest: LocalNotificationPresentation?
    }
    struct Plan {
        let presentation: LocalNotificationPresentation
        let delay: TimeInterval
    }
    private var windows: [Key: Window] = [:]
    static let interval: TimeInterval = 2
    static let maximumConversations = 32

    static func identifier(account: String, group: String) -> String {
        "foreground-chat:\(account.utf8.count):\(account):\(group)"
    }

    mutating func schedule(
        _ incoming: LocalNotificationPresentation,
        now: TimeInterval,
        previewMode: NotificationPreviewMode
    ) -> Plan {
        windows = windows.filter { $0.value.deadline > now }
        var base = incoming
        let key = Key(account: base.route.accountRef, group: base.route.groupIdHex)
        let identifier = Self.identifier(account: key.account, group: key.group)
        var window = windows[key] ?? Window(deadline: now + Self.interval, keys: [], containsMention: false)
        // Bound host state even during a pathological multi-conversation flood.
        let canRetain = windows[key] != nil || windows.count < Self.maximumConversations
        if !window.keys.contains(base.route.notificationKey) {
            window.count = window.count == Int.max ? Int.max : window.count + 1
            if window.keys.count < 512 { window.keys.insert(base.route.notificationKey) }
        }
        window.containsMention = window.containsMention || LocalNotificationProjection.isMention(from: base.userInfo)
        if let latest = window.latest, latest.timestamp > base.timestamp { base = latest }
        window.latest = base
        if canRetain { windows[key] = window }
        let route = LocalNotificationRoute(accountRef: key.account, groupIdHex: key.group,
            notificationKey: identifier, messageIdHex: base.route.messageIdHex)
        var info = base.userInfo
        info.merge(LocalNotificationProjection.userInfo(for: route), uniquingKeysWith: { _, new in new })
        info[LocalNotificationProjection.isMentionKey] = window.containsMention ? "1" : "0"
        let summary = window.count > 1
        var presentation = LocalNotificationPresentation(
            identifier: identifier, threadIdentifier: base.threadIdentifier,
            title: base.title,
            body: summary && previewMode != .generic
                ? L10n.plural("%lld new messages", Int64(window.count)) : base.body,
            route: route, timestamp: base.timestamp, userInfo: info,
            categoryIdentifier: base.categoryIdentifier)
        if !summary {
            presentation.senderName = base.senderName
            presentation.senderAccountIdHex = base.senderAccountIdHex
            presentation.senderPictureUrl = base.senderPictureUrl
            presentation.isGroupConversation = base.isGroupConversation
        }
        return Plan(presentation: presentation, delay: canRetain ? max(0.01, window.deadline - now) : 0)
    }

    mutating func cancel(account: String? = nil, group: String? = nil, readMessages: Set<String>? = nil) -> [String] {
        let keys = windows.keys.filter { key in
            guard account == nil || key.account == account, group == nil || key.group == group else { return false }
            guard let readMessages else { return true }
            return windows[key]?.latest?.route.messageIdHex.map(readMessages.contains) ?? false
        }
        for key in keys { windows[key] = nil }
        return keys.map { Self.identifier(account: $0.account, group: $0.group) }
    }
}
