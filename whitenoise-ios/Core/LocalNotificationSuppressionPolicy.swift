struct VisibleChatRoute: Equatable {
    let accountRef: String
    let groupIdHex: String
}

enum LocalNotificationSuppressionPolicy {
    static func shouldPresent(
        localNotificationsEnabled: Bool,
        isArchived: Bool = false,
        notifyMode: ChatNotifyMode = .all,
        isMention: Bool = false,
        mentionsBreakThroughMute: Bool = false,
        appSceneActive: Bool,
        updateAccountRef: String,
        updateGroupIdHex: String,
        visibleChat: VisibleChatRoute?
    ) -> Bool {
        NotificationPresentationPolicy.shouldPresent(
            localNotificationsEnabled: localNotificationsEnabled,
            isArchived: isArchived,
            notifyMode: notifyMode,
            isMention: isMention,
            mentionsBreakThroughMute: mentionsBreakThroughMute,
            appSceneActive: appSceneActive,
            updateAccountRef: updateAccountRef,
            updateGroupIdHex: updateGroupIdHex,
            visibleAccountRef: visibleChat?.accountRef,
            visibleGroupIdHex: visibleChat?.groupIdHex
        )
    }

    /// `willPresent` re-evaluates an already-built notification from its
    /// persisted metadata. A missing mention bit reads as a mention there (so
    /// only an explicit non-mention is suppressible by mentions-only), and a
    /// missing account id resolves the chat as muted. Neither guess may break
    /// through a mute: only an explicit mention from a resolvable chat does.
    static func storedNotificationBreaksThroughMute(
        userInfo: [AnyHashable: Any],
        preference: Bool
    ) -> Bool {
        guard preference,
              LocalNotificationProjection.accountIdHex(from: userInfo) != nil,
              let rawMention = userInfo[LocalNotificationProjection.isMentionKey] as? String
        else { return false }
        return rawMention == "1"
    }
}
