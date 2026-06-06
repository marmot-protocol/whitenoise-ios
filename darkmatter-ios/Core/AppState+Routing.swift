import Foundation

extension AppState {
    @MainActor
    func presentProfile(npub: String) {
        navigation.presentProfile(npub: npub)
    }

    @MainActor
    func clearPendingProfile() {
        navigation.clearPendingProfile()
    }

    /// Request navigation into a chat (e.g. just after creating one).
    @MainActor
    func presentChat(groupIdHex: String, accountRef: String? = nil, messageIdHex: String? = nil) {
        if let accountRef = navigation.presentChat(
            groupIdHex: groupIdHex,
            accountRef: accountRef,
            messageIdHex: messageIdHex
        ) {
            activeAccountRef = accountRef
        }
    }

    @MainActor
    func presentNotification(route: LocalNotificationRoute) {
        presentChat(
            groupIdHex: route.groupIdHex,
            accountRef: route.accountRef,
            messageIdHex: route.messageIdHex
        )
    }

    @MainActor
    func clearPendingChat() {
        navigation.clearPendingChat()
    }

    @MainActor
    @discardableResult
    func beginViewingChat(groupIdHex: String) -> VisibleChatRoute? {
        navigation.beginViewingChat(groupIdHex: groupIdHex, activeAccountRef: activeAccountRef)
    }

    @MainActor
    func endViewingChat(_ route: VisibleChatRoute) {
        navigation.endViewingChat(route)
    }

    func isViewingNotificationDestination(accountRef: String, groupIdHex: String) -> Bool {
        navigation.isViewingNotificationDestination(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            appSceneActive: isAppSceneActive
        )
    }

    /// Route an inbound deep link (from `.onOpenURL`).
    @MainActor
    func handle(url: URL) {
        switch DeepLink.parse(url) {
        case .profile(let npub):
            presentProfile(npub: npub)
        case .chat(let groupIdHex):
            presentChat(groupIdHex: groupIdHex)
        case nil:
            break
        }
    }
}
