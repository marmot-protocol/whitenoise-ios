import Foundation

nonisolated enum ChatRowStatusPresentation {
    enum Status: Equatable {
        case invitation
        case unread(UInt64)
        case none
    }

    static let invitationSymbolName = "plus"

    static func status(
        isInvitationPending: Bool,
        hasUnread: Bool,
        unreadCount: UInt64
    ) -> Status {
        if isInvitationPending { return .invitation }
        if hasUnread { return .unread(unreadCount) }
        return .none
    }
}
