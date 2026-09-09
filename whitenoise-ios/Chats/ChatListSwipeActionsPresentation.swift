import MarmotKit

/// Pure swipe-action policy for chat-list rows (#345). Inactive memberships
/// (`left` / `removed`) keep archive controls but swap leave for local delete.
nonisolated enum ChatListSwipeActionsPresentation: Equatable {
    nonisolated struct Actions: OptionSet, Equatable {
        let rawValue: Int

        static let leave = Actions(rawValue: 1 << 0)
        static let archive = Actions(rawValue: 1 << 1)
        static let unarchive = Actions(rawValue: 1 << 2)
        static let delete = Actions(rawValue: 1 << 3)
        static let mute = Actions(rawValue: 1 << 4)
        static let unmute = Actions(rawValue: 1 << 5)
        static let read = Actions(rawValue: 1 << 6)
        static let unread = Actions(rawValue: 1 << 7)
        static let pin = Actions(rawValue: 1 << 8)
        static let unpin = Actions(rawValue: 1 << 9)
    }

    static func leadingActions(
        hasUnread: Bool,
        isPinned: Bool,
        isArchived: Bool
    ) -> Actions {
        var actions: Actions = [hasUnread ? .read : .unread]
        if !isArchived {
            actions.insert(isPinned ? .unpin : .pin)
        }
        return actions
    }

    static func trailingActions(
        isArchived: Bool,
        selfMembership: SelfMembershipFfi,
        leaveRequestPending: Bool,
        isMuted: Bool
    ) -> Actions {
        let departureAction = ChatDepartureAction.action(
            membership: selfMembership,
            leaveRequestPending: leaveRequestPending
        )
        // No honest destructive action: the SelfRemove is out but the group has
        // not committed it, so a second leave is rejected and dropping the local
        // copy while still a member would strand the conversation.
        guard let departureAction else {
            return isArchived ? [.unarchive] : [.archive]
        }

        if isArchived {
            return departureAction == .leave ? [.unarchive, .leave] : [.unarchive, .delete]
        }

        var actions: Actions = [.archive]
        if departureAction == .leave {
            actions.insert(.leave)
            actions.insert(isMuted ? .unmute : .mute)
        } else {
            actions.insert(.delete)
        }
        return actions
    }
}
