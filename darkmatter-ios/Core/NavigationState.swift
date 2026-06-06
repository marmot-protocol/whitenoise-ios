import Foundation
import Observation

struct AppProfileLink: Identifiable, Equatable {
    let npub: String
    var id: String { npub }
}

@Observable
final class NavigationState {
    private(set) var pendingProfile: AppProfileLink?
    private(set) var pendingChatId: String?
    private(set) var pendingChatAccountRef: String?
    private(set) var pendingChatMessageIdHex: String?
    private(set) var visibleChat: VisibleChatRoute?

    @MainActor
    func presentProfile(npub: String) {
        pendingProfile = AppProfileLink(npub: npub)
    }

    @MainActor
    func clearPendingProfile() {
        pendingProfile = nil
    }

    @MainActor
    func presentChat(
        groupIdHex: String,
        accountRef: String? = nil,
        messageIdHex: String? = nil
    ) -> String? {
        let activatedAccountRef: String?
        if let accountRef, !accountRef.isEmpty {
            pendingChatAccountRef = accountRef
            activatedAccountRef = accountRef
        } else {
            pendingChatAccountRef = nil
            activatedAccountRef = nil
        }

        let messageId = messageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingChatMessageIdHex = messageId?.isEmpty == false ? messageId : nil
        pendingChatId = groupIdHex
        return activatedAccountRef
    }

    @MainActor
    func clearPendingChat() {
        pendingChatId = nil
        pendingChatAccountRef = nil
        pendingChatMessageIdHex = nil
    }

    @MainActor
    @discardableResult
    func beginViewingChat(groupIdHex: String, activeAccountRef: String?) -> VisibleChatRoute? {
        guard let activeAccountRef else { return nil }
        let route = VisibleChatRoute(accountRef: activeAccountRef, groupIdHex: groupIdHex)
        visibleChat = route
        return route
    }

    @MainActor
    func endViewingChat(_ route: VisibleChatRoute) {
        if visibleChat == route {
            visibleChat = nil
        }
    }

    func isViewingNotificationDestination(
        accountRef: String,
        groupIdHex: String,
        appSceneActive: Bool
    ) -> Bool {
        !LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            appSceneActive: appSceneActive,
            updateAccountRef: accountRef,
            updateGroupIdHex: groupIdHex,
            visibleChat: visibleChat
        )
    }
}
