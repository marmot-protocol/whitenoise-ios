struct VisibleChatRoute: Equatable {
    let accountRef: String
    let groupIdHex: String
}

enum LocalNotificationSuppressionPolicy {
    static func shouldPresent(
        localNotificationsEnabled: Bool,
        appSceneActive: Bool,
        updateAccountRef: String,
        updateGroupIdHex: String,
        visibleChat: VisibleChatRoute?
    ) -> Bool {
        guard localNotificationsEnabled else { return false }
        guard appSceneActive else { return true }
        guard let visibleChat else { return true }
        return visibleChat.accountRef != updateAccountRef
            || visibleChat.groupIdHex != updateGroupIdHex
    }
}
