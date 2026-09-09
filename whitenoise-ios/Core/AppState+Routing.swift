import Foundation
import MarmotKit

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
        let requestedAccountRef = accountRef?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedAccountRef, !requestedAccountRef.isEmpty {
            guard canRoute(toAccountRef: requestedAccountRef) else { return }
            if let accountRef = navigation.presentChat(
                groupIdHex: groupIdHex,
                accountRef: requestedAccountRef,
                messageIdHex: messageIdHex
            ) {
                activeAccountRef = accountRef
            }
            return
        }

        _ = navigation.presentChat(
            groupIdHex: groupIdHex,
            accountRef: nil,
            messageIdHex: messageIdHex
        )
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
        productActivation(.foregroundDeepLink)
        switch DeepLink.parse(url) {
        case .profile(let npub):
            presentProfile(npub: npub)
        case .chat(let groupIdHex):
            presentChat(groupIdHex: groupIdHex)
        case nil:
            break
        }
    }

    private func canRoute(toAccountRef accountRef: String) -> Bool {
        accounts.contains { account in
            account.label == accountRef && !account.signedOut
        }
    }
}
